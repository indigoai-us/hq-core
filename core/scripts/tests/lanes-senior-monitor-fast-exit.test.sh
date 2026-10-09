#!/usr/bin/env bash
# The lane monitor must avoid the hq startup cost when this session has no
# active lane records, while preserving the reminder output when a lane exists.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || fail "node is required for the bounded hq runner"

ROOT="$TMP/hq"
BIN="$TMP/bin"
NODE_DIR="${NODE_BIN%/*}"
CACHE="$TMP/cache"
CALLS="$TMP/hq.calls"
JQ_CALLS="$TMP/jq.calls"
REAL_JQ="$(command -v jq)"
OUT="$TMP/hook.out"
ERR="$TMP/hook.err"
mkdir -p "$ROOT/core/scripts/lib" "$ROOT/workspace/lanes/lanes" "$BIN" "$TMP/shims"
 : > "$CALLS"
cp "$SRC/core/scripts/lib/lanes-senior-monitor.sh" "$ROOT/core/scripts/lib/lanes-senior-monitor.sh"
cp "$SRC/core/scripts/lib/session-auto-bind.sh" "$ROOT/core/scripts/lib/session-auto-bind.sh"

cat > "$BIN/hq" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$HP26_CALLS"
session=""
engine=claude
previous=""
for current in "$@"; do
  [ "$previous" != --session ] || session="$current"
  [ "$previous" != --engine ] || engine="$current"
  previous="$current"
done

if [ "${3:-}" = --reminder ]; then
  printf '%s\n' 'CLI-REMINDER'
  exit 0
fi
if [ "${HP26_STUB_MODE:-empty}" = active ]; then
  printf '{"action":"monitor-check","session_id":"%s","engine":"%s","active_lane_ids":["lane-a"],"uncovered_lane_ids":["lane-a"],"monitor_calls":[{"command":"hq lanes watch lane-a","timeout_ms":1800000,"persistent":true}]}\n' "$session" "$engine"
  exit 2
fi
printf '{"action":"monitor-check","session_id":"%s","engine":"%s","active_lane_ids":[],"uncovered_lane_ids":[]}\n' "$session" "$engine"
exit 0
SH
chmod +x "$BIN/hq"

cat > "$TMP/shims/jq" <<'SH'
#!/usr/bin/env bash
printf x >> "$HP26_JQ_CALLS"
exec "$HP26_REAL_JQ" "$@"
SH
chmod +x "$TMP/shims/jq"
export HP26_JQ_CALLS="$JQ_CALLS" HP26_REAL_JQ="$REAL_JQ"
PATH="$TMP/shims:$BIN:$NODE_DIR:/usr/bin:/bin"
export PATH

run_hook() {
  local event="$1" sid="$2" rc=0 payload started ended
  payload="$(jq -cn --arg sid "$sid" '{session_id:$sid,engine:"claude"}')"
  started="$(now_ms)"
  : > "$OUT"
  : > "$ERR"
  printf '%s' "$payload" | env \
    HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" HOME="$TMP/home" \
    XDG_CACHE_HOME="$CACHE" HP26_CALLS="$CALLS" \
    HP26_JQ_CALLS="$JQ_CALLS" HP26_REAL_JQ="$REAL_JQ" \
    PATH="$TMP/shims:$BIN:$NODE_DIR:/usr/bin:/bin" \
    bash "$ROOT/core/scripts/lib/lanes-senior-monitor.sh" "$event" \
    >"$OUT" 2>"$ERR" || rc=$?
  ended="$(now_ms)"
  RUN_MS=$((ended - started))
  return "$rc"
}

call_count() { wc -l < "$CALLS" | tr -d '[:space:]'; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

# An unrelated active lane is a positive control: the precondition must match
# the senior session, not merely test whether any lane record exists.
cat > "$ROOT/workspace/lanes/lanes/unrelated.json" <<'JSON'
{"lane_id":"unrelated","state":"running","senior":{"kind":"session","id":"other-session"}}
JSON

for event in SessionStart UserPromptSubmit; do
  : > "$TMP/empty-$event-ms"
  run_hook "$event" "empty-$event" || fail "$event empty-session hook returned nonzero"
  [ ! -s "$OUT" ] || fail "$event empty-session wrote stdout"
  [ ! -s "$ERR" ] || fail "$event empty-session wrote stderr"
  [ "$(call_count)" = 0 ] || fail "$event empty-session launched hq despite no matching lane record"
  printf '%s\n' "$RUN_MS" > "$TMP/empty-$event-ms"
  pass "$event with no lanes is silent and does not launch hq"
done

# Hundreds of unrelated records must stay on the bounded no-lane path. The
# hook uses at most one jq process to validate the complete store (plus the
# existing payload extraction process), while preserving the empty result.
for i in $(seq 1 500); do
  printf '{"lane_id":"unrelated-%s","state":"done","senior":{"kind":"session","id":"other-%s"}}\n' "$i" "$i" \
    > "$ROOT/workspace/lanes/lanes/fixture-$i.json"
done
TIMEFORMAT='%3U %3S'
: > "$TMP/500-cpu-ms"
: > "$TMP/500-wall-ms"
lane_records=("$ROOT/workspace/lanes/lanes"/*.json)
# Confirm the fixture takes the no-match branch before measuring its one-jq
# validation stage. The hook integration below gates the complete path.
if grep -Fq -- '"many-unrelated"' "${lane_records[@]}" 2>/dev/null; then GREPRC=0; else GREPRC=$?; fi
[ "$GREPRC" -eq 1 ] || fail "500-record fixture unexpectedly matched the session"
for i in $(seq 1 20); do
  saved_path="$PATH"
  PATH="$BIN:$NODE_DIR:/usr/bin:/bin"
  set +e
  { time jq -e -n 'all(inputs; type == "object")' "${lane_records[@]}" >/dev/null; } 2> "$TMP/cpu-time"
  SCAN_RC=$?
  set -e
  PATH="$saved_path"
  [ "$SCAN_RC" -eq 0 ] || fail "500-record validation failed"
  awk '{printf "%d\n", ($1 + $2) * 1000}' "$TMP/cpu-time" >> "$TMP/500-cpu-ms"

  : > "$CALLS"
  : > "$JQ_CALLS"
  run_hook UserPromptSubmit many-unrelated || fail "500-record no-lane hook returned nonzero"
  [ ! -s "$OUT" ] || fail "500-record no-lane hook wrote stdout"
  [ ! -s "$ERR" ] || fail "500-record no-lane hook wrote stderr"
  [ "$(call_count)" = 0 ] || fail "500-record no-lane hook launched hq"
  JQ_FAST_COUNT="$(wc -c < "$JQ_CALLS" | tr -d '[:space:]')"
  [ "$JQ_FAST_COUNT" -le 3 ] \
    || fail "500-record no-lane path launched $JQ_FAST_COUNT jq processes (budget 3); wall=${RUN_MS}ms"
  printf '%s\n' "$RUN_MS" >> "$TMP/500-wall-ms"
done
CPU_P95="$(sort -n "$TMP/500-cpu-ms" | sed -n '19p')"
[ "$CPU_P95" -lt 20 ] \
  || fail "500-record one-jq validation CPU p95=${CPU_P95}ms (budget 20ms)"
printf 'PASS: 500-record no-lane path used at most %s jq processes; validation CPU p95=%sms (budget 20ms), hook wall p50=%sms (diagnostic)\n' \
  "$JQ_FAST_COUNT" "$CPU_P95" "$(sort -n "$TMP/500-wall-ms" | sed -n '10p')"
for i in $(seq 501 616); do
  printf '{"lane_id":"unrelated-%s","state":"done","senior":{"kind":"session","id":"other-%s"}}\n' "$i" "$i" \
    > "$ROOT/workspace/lanes/lanes/fixture-$i.json"
done
: > "$TMP/616-wall-ms"
for i in 1 2 3 4 5; do
  : > "$CALLS"
  : > "$JQ_CALLS"
  run_hook UserPromptSubmit many-unrelated || fail "616-record no-lane hook run $i returned nonzero"
  [ ! -s "$OUT" ] || fail "616-record no-lane hook run $i wrote stdout"
  [ ! -s "$ERR" ] || fail "616-record no-lane hook run $i wrote stderr"
  [ "$(call_count)" = 0 ] || fail "616-record no-lane hook run $i launched hq"
  JQ_FAST_COUNT="$(wc -c < "$JQ_CALLS" | tr -d '[:space:]')"
  [ "$JQ_FAST_COUNT" -le 3 ] || fail "616-record no-lane path launched $JQ_FAST_COUNT jq processes (budget 3)"
  printf '%s\n' "$RUN_MS" >> "$TMP/616-wall-ms"
done
printf 'PASS: 616-record no-lane hook wall p50=%sms (diagnostic), jq processes=%s\n' \
  "$(sort -n "$TMP/616-wall-ms" | sed -n '3p')" "$JQ_FAST_COUNT"
rm -f "$ROOT/workspace/lanes/lanes"/fixture-*.json

for i in 1 2 3 4; do
  for event in SessionStart UserPromptSubmit; do
    run_hook "$event" "empty-$event-$i" || fail "$event empty-session timing sample $i returned nonzero"
    [ ! -s "$OUT" ] || fail "$event empty-session timing sample $i wrote stdout"
    [ ! -s "$ERR" ] || fail "$event empty-session timing sample $i wrote stderr"
    [ "$(call_count)" = 0 ] || fail "$event empty-session timing sample $i launched hq"
    printf '%s\n' "$RUN_MS" >> "$TMP/empty-$event-ms"
  done
done
printf 'PASS: no-lane timing medians (diagnostic): SessionStart=%sms UserPromptSubmit=%sms (5 runs each)\n' \
  "$(sort -n "$TMP/empty-SessionStart-ms" | sed -n '3p')" \
  "$(sort -n "$TMP/empty-UserPromptSubmit-ms" | sed -n '3p')"

# Malformed lane data cannot justify the no-lane fast exit. Fall through to the
# CLI so its regular parser and diagnostics remain authoritative.
printf '%s\n' '{malformed' > "$ROOT/workspace/lanes/lanes/malformed.json"
run_hook UserPromptSubmit malformed-session || fail "malformed lane record changed the hook exit"
[ ! -s "$OUT" ] || fail "malformed lane record changed empty monitor output"
[ "$(call_count)" = 1 ] || fail "malformed lane data did not fall through to hq"
pass "malformed lane JSON falls through to the CLI"
rm "$ROOT/workspace/lanes/lanes/malformed.json"

cat > "$ROOT/workspace/lanes/lanes/lane-a.json" <<'JSON'
{"lane_id":"lane-a","state":"running","senior":{"kind":"session","id":"with-lanes"}}
JSON
export HP26_STUB_MODE=active
run_hook SessionStart with-lanes || fail "active SessionStart returned nonzero"
jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | contains("CLI-REMINDER") and contains("lane-a") and contains("hq lanes watch lane-a"))' "$OUT" >/dev/null \
  || fail "active lane reminder output changed"
[ "$(call_count)" = 3 ] || fail "active SessionStart did not make the JSON and reminder calls"
pass "active lane SessionStart preserves reminder and Monitor-call output"

run_hook UserPromptSubmit with-lanes || fail "cached UserPromptSubmit returned nonzero"
[ ! -s "$OUT" ] || fail "seen active lane repeated on UserPromptSubmit"
[ "$(call_count)" = 3 ] || fail "UserPromptSubmit did not reuse the per-session cache"
printf '%s\n' "$RUN_MS" > "$TMP/prompt-ms"
pass "active lane UserPromptSubmit reuses the per-session cache"

run_hook SessionStart with-lanes || fail "uncached SessionStart returned nonzero"
[ ! -s "$OUT" ] || fail "seen active lane repeated on SessionStart"
[ "$(call_count)" = 4 ] || fail "SessionStart did not refresh monitor-check from the CLI"
printf '%s\n' "$RUN_MS" > "$TMP/start-ms"
pass "SessionStart refreshes monitor-check instead of using the TTL cache"

for i in 1 2 3 4; do
  run_hook UserPromptSubmit with-lanes || fail "cached UserPromptSubmit sample $i returned nonzero"
  [ "$(call_count)" = "$((3 + i))" ] || fail "UserPromptSubmit sample $i did not reuse cache"
  printf '%s\n' "$RUN_MS" >> "$TMP/prompt-ms"
  run_hook SessionStart with-lanes || fail "uncached SessionStart sample $i returned nonzero"
  [ "$(call_count)" = "$((4 + i))" ] || fail "SessionStart sample $i did not refresh monitor-check"
  printf '%s\n' "$RUN_MS" >> "$TMP/start-ms"
done
printf 'PASS: active-lane timing medians (diagnostic): SessionStart=%sms UserPromptSubmit=%sms (5 runs each)\n' \
  "$(sort -n "$TMP/start-ms" | sed -n '3p')" "$(sort -n "$TMP/prompt-ms" | sed -n '3p')"

# A previously empty SessionStart result must not hide a done-to-running change.
TRANSITION_SESSION="transition-session"
printf '%s\n' '{"lane_id":"transition","state":"done","senior":{"kind":"session","id":"transition-session"}}' > "$ROOT/workspace/lanes/lanes/transition.json"
export HP26_STUB_MODE=empty
run_hook SessionStart "$TRANSITION_SESSION" || fail "done transition setup SessionStart failed"
[ ! -s "$OUT" ] || fail "done transition setup emitted output"
[ "$(call_count)" = 9 ] || fail "done transition setup did not call hq"
printf '%s\n' '{"lane_id":"transition","state":"running","senior":{"kind":"session","id":"transition-session"}}' > "$ROOT/workspace/lanes/lanes/transition.json"
export HP26_STUB_MODE=active
run_hook SessionStart "$TRANSITION_SESSION" || fail "running transition SessionStart failed"
jq -e '.hookSpecificOutput.additionalContext | contains("lane-a")' "$OUT" >/dev/null || fail "done-to-running transition was hidden by cache"
[ "$(call_count)" = 11 ] || fail "done-to-running transition did not refresh hq results"
pass "SessionStart observes a done-to-running lane transition within the TTL"
