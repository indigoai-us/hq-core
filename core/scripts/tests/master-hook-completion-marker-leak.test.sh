#!/usr/bin/env bash
# hq-core: public
# master-hook-completion-marker-leak.test.sh — master-hook.sh leaves no
# per-child completion marker (<invocation>.<n>.done) in
# workspace/.hook-timeout-completions once a dispatch finishes.
#
# The leak: a registry hook that runs through the hq-hook engine bridge gets
# a marker for the bridge run. When the engine gave no verdict (any exit but
# 0 or 2, for example 75 when the script hash is not pinned), the sequential
# path took a second marker for the bash fallback and never queued the first
# for removal, so every such event left one zero-byte file. The age-based
# sweep only removes markers older than an hour, so until then each leaked
# file adds to the directory that every event globs.
#
# Sections:
#   [a] sequential, no engine: no marker left
#   [b] sequential, engine gives a verdict: no marker left
#   [c] sequential, engine exits 75 (no verdict): the bash hook runs and no
#       marker is left, also after ten more events
#   [d] parallel (bash 5.1 or later), engine exits 75: no marker left
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl unavailable" >&2; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-marker-leak.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
FIX="$TMP/hq"
FAKE_HOME="$TMP/home"
CACHE="$FAKE_HOME/.cache"
ENGINE="$TMP/engine"
STUB="$ENGINE/hq-hook"
PLAN="$ENGINE/plan.txt"
COMP="$FIX/workspace/.hook-timeout-completions"
HOOK_ID="fixture-port"
PLAIN_ID="fixture-plain"
# The interpreter under test is pinned: HQ_TEST_BASH when set, else /bin/bash
# (what settings.json resolves on macOS), else the first bash on PATH.
TEST_BASH="${HQ_TEST_BASH:-/bin/bash}"
[ -x "$TEST_BASH" ] || TEST_BASH="$(command -v bash)"
echo "interpreter under test: $TEST_BASH ($("$TEST_BASH" -c 'echo "$BASH_VERSION"'))"
# Parallel dispatch needs bash 5.1 or later. Use the pinned interpreter when it qualifies, else the
# first bash on PATH that does.
is_bash51() { "$1" -c '[ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }' 2>/dev/null; }
BASH51=""
if is_bash51 "$TEST_BASH"; then
  BASH51="$TEST_BASH"
elif command -v bash >/dev/null 2>&1 && is_bash51 "$(command -v bash)"; then
  BASH51="$(command -v bash)"
fi
mkdir -p "$FAKE_HOME" "$CACHE/hq/flags" "$ENGINE"

mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts/lib" "$FIX/workspace/orchestrator"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
for f in hook-timeout-probe.sh hook-timeout-watchdog.sh hook-gate.sh; do
  cp "$ROOT/.claude/hooks/$f" "$FIX/.claude/hooks/"
done
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$ROOT/core/scripts/lib/trigger-fact-text.awk" "$FIX/core/scripts/lib/"
[ ! -f "$ROOT/core/scripts/lib/perl-child-locale.sh" ] \
  || cp "$ROOT/core/scripts/lib/perl-child-locale.sh" "$FIX/core/scripts/lib/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$FIX/core/scripts/"
printf 'hqVersion: "15.0.131"\n' > "$FIX/core/core.yaml"
for id in "$HOOK_ID" "$PLAIN_ID"; do
  cat > "$FIX/.claude/hooks/$id.sh" <<HOOK
#!/usr/bin/env bash
cat >/dev/null
here="\$(cd "\$(dirname "\$0")" && pwd)"
printf '$id\n' >> "\$here/ran.log"
exit 0
HOOK
  chmod +x "$FIX/.claude/hooks/$id.sh"
done
jq -nc --arg id "$HOOK_ID" --arg s ".claude/hooks/$HOOK_ID.sh" \
  --arg pid "$PLAIN_ID" --arg ps ".claude/hooks/$PLAIN_ID.sh" '
  {hooks: {PreToolUse: [{matcher: "Bash", hooks: [
    {id: $id, script: $s, timeout: 7, gated: false, runner: "exec", args: ["PreToolUse"]},
    {id: $pid, script: $ps, timeout: 7, gated: false, runner: "exec", args: ["PreToolUse"]}
  ]}]}}' > "$FIX/.claude/hooks/hook-registry.json"

# Stub hq-hook: bridge-plan prints plan.txt; bridge exits with the code in
# bridge-rc when that file exists (no verdict), else prints a verdict.
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
cmd="${1:-}"
case "$cmd" in
  bridge-plan)
    [ ! -f "$here/plan.txt" ] || cat "$here/plan.txt"
    exit 0
    ;;
  bridge)
    cat >/dev/null
    printf 'bridge\n' >> "$here/calls.log"
    [ ! -f "$here/bridge-rc" ] || exit "$(cat "$here/bridge-rc")"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"bridged"}}\n'
    exit 0
    ;;
esac
exit 2
STUB
chmod +x "$STUB"
printf '%s\n' '{"flags":{"hook-engine-port-fixture-port":"on","hq-anywhere-runtime":false}}' \
  > "$CACHE/hq/flags/snapshot-cmp_123456.json"
printf '%s\t%s\n' "$HOOK_ID" on > "$PLAN"

PAYLOAD="$(jq -nc --arg d "$FIX" '{session_id:"marker-leak",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:"echo hi"}}')"

# run [ENV=VALUE ...] -> RC. RUN_BASH picks the interpreter.
RUN_BASH="$TEST_BASH"
run() {
  RC=0
  printf '%s' "$PAYLOAD" | (cd "$FIX" && env HOME="$FAKE_HOME" XDG_CACHE_HOME="$CACHE" \
    HQ_HOOK_PROFILE=standard CLAUDE_PROJECT_DIR="$FIX" HQ_ROOT="$FIX" \
    HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=0 HQ_FLAGS_API_URL= HQ_COMPANY_UID= \
    "$@" "$RUN_BASH" "$FIX/.claude/hooks/master-hook.sh" PreToolUse) \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
}
reset_logs() { rm -f "$ENGINE/calls.log" "$ENGINE/bridge-rc" "$FIX/.claude/hooks/ran.log"; }
ran() { # <id>: times the bash hook ran
  [ -f "$FIX/.claude/hooks/ran.log" ] || { echo 0; return; }
  grep -c "^$1\$" "$FIX/.claude/hooks/ran.log" || true
}
bridge_calls() {
  [ -f "$ENGINE/calls.log" ] || { echo 0; return; }
  grep -c '^bridge$' "$ENGINE/calls.log" || true
}
# Markers and parallel result files in the completions directory.
left_names() {
  [ -d "$COMP" ] || return 0
  find "$COMP" -maxdepth 1 -type f \( -name '*.done' -o -name '*.done.fb' -o -name '*.par.*' \) 2>/dev/null \
    | sed 's|.*/||' | sort
}
left_count() { left_names | grep -c . || true; }
no_markers() { # <label>
  local n
  n="$(left_count)"
  [ "$n" = "0" ] && ok "$1: no marker left in .hook-timeout-completions" \
    || bad "$1: $n file(s) left: $(left_names | head -n 5 | tr '\n' ' ')"
  # Start the next section clean, so one leak is reported once.
  [ "$n" = "0" ] || find "$COMP" -maxdepth 1 -type f \( -name '*.done' -o -name '*.done.fb' -o -name '*.par.*' \) \
    -exec rm -f {} + 2>/dev/null
}

echo "[a] sequential, no engine"
reset_logs
run
[ "$RC" = "0" ] && [ "$(ran "$HOOK_ID")" = "1" ] && [ "$(ran "$PLAIN_ID")" = "1" ] \
  && ok "both hooks ran (rc 0)" || bad "rc=$RC ran=$(ran "$HOOK_ID")/$(ran "$PLAIN_ID") err=$(head -c 300 "$TMP/err")"
[ -d "$COMP" ] && ok "completions directory is in use" \
  || bad "no completions directory: this host has no timeout runner, so the fixture is not exercising markers"
no_markers "[a]"

echo "[b] sequential, engine gives a verdict"
reset_logs
run HQ_HOOK_ENGINE_BIN="$STUB"
[ "$RC" = "0" ] && [ "$(bridge_calls)" = "1" ] && [ "$(ran "$HOOK_ID")" = "0" ] \
  && ok "engine ran instead of the bash hook" \
  || bad "rc=$RC bridge=$(bridge_calls) bash=$(ran "$HOOK_ID") err=$(head -c 300 "$TMP/err")"
no_markers "[b]"

echo "[c] sequential, engine exits 75 without a verdict"
reset_logs
echo 75 > "$ENGINE/bridge-rc"
run HQ_HOOK_ENGINE_BIN="$STUB"
[ "$RC" = "0" ] && [ "$(bridge_calls)" = "1" ] && [ "$(ran "$HOOK_ID")" = "1" ] \
  && ok "engine was tried, then the bash hook ran" \
  || bad "rc=$RC bridge=$(bridge_calls) bash=$(ran "$HOOK_ID") err=$(head -c 300 "$TMP/err")"
no_markers "[c]"
# Ten such events in a row, as on a machine whose engine pins lag its core.
for _ in 1 2 3 4 5 6 7 8 9 10; do run HQ_HOOK_ENGINE_BIN="$STUB"; done
no_markers "[c] after ten more events"

echo "[d] parallel, engine exits 75 without a verdict"
if [ -n "$BASH51" ]; then
  reset_logs
  echo 75 > "$ENGINE/bridge-rc"
  RUN_BASH="$BASH51"
  run HQ_HOOK_ENGINE_BIN="$STUB" HQ_HOOK_PARALLEL=1
  RUN_BASH="$TEST_BASH"
  [ "$RC" = "0" ] && [ "$(bridge_calls)" = "1" ] && [ "$(ran "$HOOK_ID")" = "1" ] && [ "$(ran "$PLAIN_ID")" = "1" ] \
    && ok "engine was tried, then the bash hook ran ($BASH51)" \
    || bad "rc=$RC bridge=$(bridge_calls) bash=$(ran "$HOOK_ID")/$(ran "$PLAIN_ID") err=$(head -c 300 "$TMP/err")"
  no_markers "[d]"
else
  echo "note: no bash 5.1 or later on this host; parallel dispatch stays sequential there, covered by [c]"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
