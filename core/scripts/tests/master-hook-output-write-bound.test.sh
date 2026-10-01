#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
WATCHDOG="$ROOT/.claude/hooks/hook-timeout-watchdog.sh"
PROBE="$ROOT/.claude/hooks/hook-timeout-probe.sh"
. "$PROBE"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/hooks/PostToolUse" "$FIX/core/scripts/lib" "$FIX/workspace/sessions" "$FIX/workspace/.hook-timeout-journal"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIX/.claude/hooks/"
cat > "$FIX/.claude/hooks/hook-timeout-watchdog.sh" <<'EOF'
#!/usr/bin/env bash
# Keep the test focused on master phase persistence, not the watcher process.
exit 0
EOF
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIX/.claude/hooks/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/"
chmod +x "$FIX/.claude/hooks/master-hook.sh"

cat > "$FIX/core/hooks/PostToolUse/99-large-plain-output.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf started > "$HQ_TEST_MARKER"
head -c 1048576 /dev/zero | tr '\0' x
EOF
chmod +x "$FIX/core/hooks/PostToolUse/99-large-plain-output.sh"
printf '%s\n' '{"session_id":"output-write-test","tool_name":"Bash","tool_input":{"command":"true"}}' > "$TMP/input.json"
mkfifo "$TMP/stdout.fifo"
# Open the read end immediately, but deliberately do not drain it. The hook's
# 1 MiB plain-text write fills the pipe and models a harness that stopped reading.
(
  exec 3<"$TMP/stdout.fifo"
  sleep 30 &
  sleeper=$!
  trap 'kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true' TERM
  wait "$sleeper"
  cat <&3 >/dev/null
) &
consumer=$!
hook_timeout_realtime_ms || { echo 'FAIL: high-resolution timer unavailable' >&2; exit 1; }
start_ms="$HOOK_TIMEOUT_REALTIME_MS"
set +e
hook_timeout_run_bounded 9 env HQ_TEST_MARKER="$FIX/child-ran" HQ_HOOK_TIMEOUT_SENTRY=1 \
  HQ_MASTER_CHILD_TIMEOUT=2 CLAUDE_PROJECT_DIR="$FIX" \
  bash "$FIX/.claude/hooks/master-hook.sh" PostToolUse \
  <"$TMP/input.json" >"$TMP/stdout.fifo" 2>"$TMP/stderr.log" &
runner=$!
wait "$runner" || rc=$?
rc="${rc:-0}"
set -e
hook_timeout_realtime_ms || { echo 'FAIL: high-resolution timer unavailable after hook' >&2; exit 1; }
end_ms="$HOOK_TIMEOUT_REALTIME_MS"
elapsed_ms=$((end_ms - start_ms))
kill "$consumer" 2>/dev/null || true
wait "$consumer" 2>/dev/null || true
if [ "$rc" -eq 124 ]; then
  echo "FAIL: master-hook remained blocked on undrained stdout for ${elapsed_ms}ms" >&2
  for active in "$FIX"/workspace/.hook-timeout-journal/*.active "$FIX"/workspace/.hook-timeout-journal/*.debug.tsv; do [ ! -f "$active" ] || cat "$active" >&2; done
  [ ! -f "$FIX/child-ran" ] || echo 'fixture child ran' >&2
  exit 1
fi
[ "$rc" -eq 0 ] || { echo "FAIL: master-hook exited $rc: $(cat "$TMP/stderr.log")" >&2; exit 1; }
[ "$elapsed_ms" -lt 10000 ] || { echo "FAIL: output stage exceeded 10s (${elapsed_ms}ms)" >&2; exit 1; }
phase_files=("$FIX"/workspace/.hook-timeout-journal/*.debug.tsv.active)
[ -f "${phase_files[0]}" ] || { echo 'FAIL: missing retained debug phase record for abandoned output' >&2; exit 1; }
grep -q '^output_abandoned_stdout[[:space:]]' "${phase_files[0]}" \
  || { echo 'FAIL: debug data omitted stdout abandonment reason' >&2; cat "${phase_files[0]}" >&2; exit 1; }
grep -q 'output_stdout:' "${phase_files[0]}" \
  || { echo 'FAIL: debug data omitted output stdout timing' >&2; cat "${phase_files[0]}" >&2; exit 1; }
phase_timings="$(hook_timeout_phase_timings_json "" "${phase_files[0]}")"
jq -e '. as $timings | ["output_scan", "output_merge", "output_stdout", "output_abandoned_stdout"] as $wanted | all($wanted[]; . as $phase | any($timings[]; .phase == $phase))' \
  <<< "$phase_timings" >/dev/null \
  || { echo "FAIL: debug phase decoder omitted output sub-phases: $phase_timings" >&2; exit 1; }
for phase in output_scan output_merge output_stdout; do
  grep -Fq "$phase" "$MASTER" && grep -Fq "$phase" "$WATCHDOG" && grep -Fq "$phase" "$PROBE" \
    || { echo "FAIL: phase allowlist drift for $phase" >&2; exit 1; }
done
echo "PASS: output write bounded under undrained stdout (${elapsed_ms}ms, exit=$rc)"

# A later deny must be delivered before an earlier hook's plain output can
# consume the shared write deadline. The reader opens the FIFO but waits before
# draining it, so the pipe has room for the small deny JSON but not the 8 MiB
# advisory output.
rm -f "$FIX/core/hooks/PostToolUse"/* "$FIX/child-ran"
cat > "$FIX/core/hooks/PostToolUse/90-large-plain-output.sh" <<'EOF'
#!/usr/bin/env bash
head -c 8388608 /dev/zero | tr '\0' x
EOF
cat > "$FIX/core/hooks/PostToolUse/99-deny-output.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"}}'
EOF
chmod +x "$FIX/core/hooks/PostToolUse/"*.sh
rm -f "$TMP/stdout.fifo" "$TMP/deny-output"
mkfifo "$TMP/stdout.fifo"
(
  exec 3<"$TMP/stdout.fifo"
  sleep 12
  cat <&3 >"$TMP/deny-output"
) &
consumer=$!
set +e
hook_timeout_run_bounded 9 env HQ_HOOK_TIMEOUT_SENTRY=1 HQ_MASTER_CHILD_TIMEOUT=2 CLAUDE_PROJECT_DIR="$FIX" \
  bash "$FIX/.claude/hooks/master-hook.sh" PostToolUse \
  <"$TMP/input.json" >"$TMP/stdout.fifo" 2>"$TMP/deny-stderr.log"
rc=$?
set -e
wait "$consumer"
if [ "$rc" -ne 0 ] || ! grep -q '"permissionDecision":"deny"' "$TMP/deny-output"; then
  echo "FAIL: later deny was not delivered within bounded hook execution (exit=$rc)" >&2
  cat "$TMP/deny-stderr.log" >&2
  exit 1
fi
echo 'PASS: later deny survives an earlier blocked plain-output write'

# A jq timeout while inspecting a large possible-deny candidate must choose
# fail-closed JSON output rather than allowing the empty-index merge path.
rm -f "$FIX/core/hooks/PostToolUse"/*
cat > "$FIX/core/hooks/PostToolUse/90-large-block.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s' '{"decision":"block","reason":"'
head -c 70000 /dev/zero | tr '\0' x
printf '%s' '"}'
EOF
cat > "$FIX/core/hooks/PostToolUse/99-advisory-json.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"advisory"}}'
EOF
chmod +x "$FIX/core/hooks/PostToolUse/"*.sh
# Shorten only the fixture dispatcher's output budget so the slow jq shim
# deterministically times out during deny-candidate inspection.
sed 's/output_write_started_ms + 4000/output_write_started_ms + 1000/' "$MASTER" \
  > "$FIX/.claude/hooks/master-hook.sh"
chmod +x "$FIX/.claude/hooks/master-hook.sh"
mkdir -p "$TMP/slow-jq"
REAL_JQ="$(command -v jq)"
cat > "$TMP/slow-jq/jq" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    *'.decision == "block"'*) printf hit > "$HQ_TEST_JQ_MARKER"; sleep 3 ;;
    -sc) sleep 3 ;;
  esac
done
exec "$HQ_TEST_REAL_JQ" "$@"
EOF
chmod +x "$TMP/slow-jq/jq"
set +e
HQ_TEST_REAL_JQ="$REAL_JQ" HQ_TEST_JQ_MARKER="$TMP/slow-jq-hit" PATH="$TMP/slow-jq:$PATH" hook_timeout_run_bounded 15 env \
  HQ_HOOK_TIMEOUT_SENTRY=1 HQ_MASTER_CHILD_TIMEOUT=10 CLAUDE_PROJECT_DIR="$FIX" \
  bash "$FIX/.claude/hooks/master-hook.sh" PostToolUse \
  <"$TMP/input.json" >"$TMP/large-block-output" 2>"$TMP/large-block-stderr.log"
rc=$?
set -e
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
[ -f "$TMP/slow-jq-hit" ] || { echo 'FAIL: large-block test did not invoke the slow jq timeout shim' >&2; exit 1; }
[ "$rc" -eq 0 ] || { echo "FAIL: large-block dispatch exited $rc: $(cat "$TMP/large-block-stderr.log")" >&2; exit 1; }
grep -q '"decision":"block"' "$TMP/large-block-output" \
  || { echo 'FAIL: jq timeout on a large possible-deny candidate produced no block output' >&2; exit 1; }
echo 'PASS: large possible-deny candidate survives jq timeout'

# The dispatcher must preserve collect_output's one-newline-per-child byte
# contract. A here-string adds a second newline to the accumulated plain text.
rm -f "$FIX/core/hooks/PostToolUse"/*
cat > "$FIX/core/hooks/PostToolUse/90-first-plain.sh" <<'EOF'
#!/usr/bin/env bash
head -c 40000 /dev/zero | tr '\0' a
EOF
cat > "$FIX/core/hooks/PostToolUse/99-second-plain.sh" <<'EOF'
#!/usr/bin/env bash
head -c 40000 /dev/zero | tr '\0' b
EOF
chmod +x "$FIX/core/hooks/PostToolUse/"*.sh
head -c 40000 /dev/zero | tr '\0' a > "$TMP/plain-expected"
printf '\n' >> "$TMP/plain-expected"
head -c 40000 /dev/zero | tr '\0' b >> "$TMP/plain-expected"
printf '\n' >> "$TMP/plain-expected"
env HQ_HOOK_TIMEOUT_SENTRY=1 HQ_MASTER_CHILD_TIMEOUT=2 CLAUDE_PROJECT_DIR="$FIX" \
  bash "$FIX/.claude/hooks/master-hook.sh" PostToolUse \
  <"$TMP/input.json" >"$TMP/plain-output" 2>"$TMP/plain-stderr.log"
cmp -s "$TMP/plain-expected" "$TMP/plain-output" \
  || { echo 'FAIL: two-child plain output differs from collect_output newline contract' >&2; od -An -tx1 "$TMP/plain-output" >&2; exit 1; }
echo 'PASS: two-child plain output is byte-identical to the fixture'
