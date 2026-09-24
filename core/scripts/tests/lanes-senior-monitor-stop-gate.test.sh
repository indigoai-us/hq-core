#!/usr/bin/env bash
# hq-core: public
# Wiring tests for the hq-cli-backed lane reminder and Stop gate.
#
# Lane store parsing and Monitor evidence live in hq-cli. This suite therefore
# stubs only the CLI boundary and tests the shell wiring, engine forwarding,
# Stop protocol, loud failure paths and remedy-safe recursion guard.

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
STOP_SRC="$SRC/.claude/hooks/lanes-senior-monitor-stop-gate.sh"
REMINDER_SRC="$SRC/core/scripts/lib/lanes-senior-monitor.sh"
WRAP_SS="$SRC/core/hooks/SessionStart/45-lanes-senior-monitor.sh"
WRAP_UPS="$SRC/core/hooks/UserPromptSubmit/45-lanes-senior-monitor.sh"
MASTER_SRC="$SRC/.claude/hooks/master-hook.sh"
PROBE_SRC="$SRC/.claude/hooks/hook-timeout-probe.sh"
GATE_SRC="$SRC/.claude/hooks/hook-gate.sh"
REGISTRY_SRC="$SRC/.claude/hooks/hook-registry.json"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "  ok: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}
assert_contains() {
  contains "$1" "$2" || fail "$3: missing '$2' in: $1"
}
assert_not_contains() {
  contains "$1" "$2" && fail "$3: unexpectedly contains '$2' in: $1"
}
assert_empty() {
  [ -z "$1" ] || fail "$2: expected empty, got: $1"
}

[ -f "$STOP_SRC" ] || { echo "FAIL: missing Stop shim" >&2; exit 1; }
[ -f "$REMINDER_SRC" ] || { echo "FAIL: missing reminder shim" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

FIX="$TMP/fixture"
BIN="$TMP/bin"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/hooks" "$BIN"
cp "$MASTER_SRC" "$FIX/.claude/hooks/master-hook.sh"
cp "$PROBE_SRC" "$FIX/.claude/hooks/hook-timeout-probe.sh"
cp "$GATE_SRC" "$FIX/.claude/hooks/hook-gate.sh"
cp "$STOP_SRC" "$FIX/.claude/hooks/lanes-senior-monitor-stop-gate.sh"

jq -n '{hooks:{Stop:[{matcher:"",hooks:[{id:"lanes-senior-monitor-stop-gate",script:".claude/hooks/lanes-senior-monitor-stop-gate.sh",timeout:30,gated:true}]}]}}' \
  > "$FIX/.claude/hooks/hook-registry.json"

STUB_MODE_FILE="$TMP/stub-mode"
STUB_LOG="$TMP/stub-args.log"
STUB_ENV_LOG="$TMP/stub-env.log"
export TEST_STUB_MODE_FILE="$STUB_MODE_FILE" TEST_STUB_LOG="$STUB_LOG" TEST_STUB_ENV_LOG="$STUB_ENV_LOG"
cat > "$BIN/hq" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
cat >/dev/null 2>&1 || true
mode="$(cat "$TEST_STUB_MODE_FILE" 2>/dev/null || printf 'pass')"
printf '%s\n' "$*" >> "$TEST_STUB_LOG"
printf '%s\n' "${HQ_NO_UPDATE_CHECK:-}" >> "$TEST_STUB_ENV_LOG"
if [ "${1:-}" != "lanes" ] || [ "${2:-}" != "monitor-check" ]; then
  echo "stub hq: unexpected command" >&2
  exit 64
fi
stub_engine=claude
previous_arg=""
for current_arg in "$@"; do
  if [ "$previous_arg" = "--engine" ]; then
    stub_engine="$current_arg"
  fi
  previous_arg="$current_arg"
done
emit_check_json() {
  jq --arg engine "$stub_engine" '.engine = $engine'
}
if [ "${3:-}" = "--reminder" ]; then
  case "$mode" in
    reminder|active-a|active-b)
    printf '%s\n' 'CLI-REMINDER timeout_ms=1800000 persistent=true'
    exit 0
    ;;
  esac
  echo "stub hq: reminder unavailable" >&2
  exit 3
fi
case "$mode" in
  pass)
    printf '%s\n' '{"ok":true,"action":"monitor-check","session_id":"senior-1","engine":"claude","active_lane_ids":[],"covered_lane_ids":[],"uncovered_lane_ids":[]}' | emit_check_json
    exit 0
    ;;
  blocked)
    printf '%s\n' '{"ok":false,"action":"monitor-check","session_id":"senior-1","engine":"claude","active_lane_ids":["lane-a"],"covered_lane_ids":[],"uncovered_lane_ids":["lane-a"],"monitor_calls":[{"command":"hq lanes watch lane-a","timeout_ms":1800000,"persistent":true}]}' | emit_check_json
    exit 2
    ;;
  no-lanes|terminal)
    printf '%s\n' '{"ok":true,"action":"monitor-check","session_id":"senior-1","engine":"claude","active_lane_ids":[],"covered_lane_ids":[],"uncovered_lane_ids":[]}' | emit_check_json
    exit 0
    ;;
  active-a)
    printf '%s\n' '{"ok":false,"action":"monitor-check","session_id":"senior-1","engine":"claude","active_lane_ids":["lane-a"],"covered_lane_ids":[],"uncovered_lane_ids":["lane-a"],"monitor_calls":[{"command":"hq lanes watch lane-a","timeout_ms":1800000,"persistent":true}]}' | emit_check_json
    exit 2
    ;;
  active-b)
    printf '%s\n' '{"ok":false,"action":"monitor-check","session_id":"senior-1","engine":"claude","active_lane_ids":["lane-b"],"covered_lane_ids":[],"uncovered_lane_ids":["lane-b"],"monitor_calls":[{"command":"hq lanes watch lane-b","timeout_ms":1800000,"persistent":true}]}' | emit_check_json
    exit 2
    ;;
  error)
    echo 'stub hq: simulated monitor-check failure' >&2
    exit 3
    ;;
  hang)
    sleep 3
    echo 'stub hq: hang completed unexpectedly' >&2
    exit 3
    ;;
  *)
    echo "stub hq: unknown test mode $mode" >&2
    exit 64
    ;;
esac
SH
chmod +x "$BIN/hq"

write_mode() { printf '%s\n' "$1" > "$STUB_MODE_FILE"; }
reset_stub() {
  write_mode "$1"
  : > "$STUB_LOG"
  : > "$STUB_ENV_LOG"
}
stub_call_count() {
  wc -l < "$STUB_LOG" | tr -d '[:space:]'
}
stub_session_check_count() {
  awk '/--session/ && /--json/ { count++ } END { print count + 0 }' "$STUB_LOG"
}
monitor_cache_file() {
  find "$1/hq-cli/lanes-senior-monitor" -type f -name '*.monitor.json' -print 2>/dev/null | head -n 1
}
make_monitor_cache_stale() {
  local cache_file="$1" stale_file
  stale_file="$cache_file.stale"
  jq '.checked_at_epoch = (.checked_at_epoch - 1000)' "$cache_file" > "$stale_file" \
    && mv -f "$stale_file" "$cache_file"
}

PAYLOAD_PASS='{"session_id":"senior-1","hook_event_name":"Stop","stop_hook_active":false}'
PAYLOAD_ACTIVE='{"session_id":"senior-1","hook_event_name":"Stop","stop_hook_active":true}'
PATH_WITH_HQ="$BIN:/usr/bin:/bin"
PATH_WITHOUT_HQ="$TMP/no-hq:/usr/bin:/bin"

run_master() {
  local payload="$1" path_env="$2"; local errf outf
  errf="$(mktemp "$TMP/master-err.XXXXXX")"
  outf="$(mktemp "$TMP/master-out.XXXXXX")"
  MRC=0
  printf '%s' "$payload" | env -u HQ_HARNESS -u HQ_WORK_MESH_HARNESS -u HQ_CHECKPOINT_RUNTIME \
    HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" HQ_ALLOW_HQ_WORKTREE=1 \
    HOME="$TMP/test-home" HQ_HOOK_TIMEOUT_SENTRY=0 PATH="$path_env" bash "$FIX/.claude/hooks/master-hook.sh" Stop \
    > "$outf" 2> "$errf" || MRC=$?
  MOUT="$(cat "$outf")"
  MERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

run_direct() {
  local script="$1" payload="$2" path_env="$3" engine="${4:-claude}"; local errf outf
  errf="$(mktemp "$TMP/direct-err.XXXXXX")"
  outf="$(mktemp "$TMP/direct-out.XXXXXX")"
  DRC=0
  printf '%s' "$payload" | env HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" \
    HQ_HARNESS="$engine" HQ_HOOK_TIMEOUT_SENTRY=0 HOME="$TMP/test-home" \
    XDG_CACHE_HOME="$TMP/direct-cache" PATH="$path_env" \
    bash "$script" > "$outf" 2> "$errf" || DRC=$?
  DOUT="$(cat "$outf")"
  DERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

echo "[1] Claude Stop wiring and exit mapping"
reset_stub pass
run_master "$PAYLOAD_PASS" "$PATH_WITH_HQ"
[ "$MRC" = "0" ] && pass "no active lanes passes with exit 0" || fail "no active lanes rc=$MRC stderr=$MERR"
assert_empty "$MOUT" "no active lanes stdout"
assert_empty "$MERR" "no active lanes stderr"
contains "$(cat "$STUB_LOG")" '--engine claude' && pass "Claude engine is explicit" || fail "Claude engine was not forwarded"
contains "$(cat "$STUB_ENV_LOG")" '1' && pass "self-update is disabled for the bounded hq call" || fail "HQ_NO_UPDATE_CHECK was not set"

reset_stub blocked
run_master "$PAYLOAD_PASS" "$PATH_WITH_HQ"
[ "$MRC" = "0" ] && pass "uncovered lane maps to a structured Claude Stop block" || fail "uncovered rc=$MRC stderr=$MERR"
assert_contains "$MOUT" '"decision":"block"' "uncovered block JSON"
assert_contains "$MOUT" 'lane-a' "uncovered lane id"
assert_contains "$MOUT" 'hq lanes watch lane-a' "exact Monitor command"
assert_contains "$MOUT" 'hq lanes stop <lane-id>' "stop remedy"
assert_contains "$MOUT" 'hq lanes reparent <lane-id>' "reparent remedy"

reset_stub error
run_master "$PAYLOAD_PASS" "$PATH_WITH_HQ"
[ "$MRC" = "0" ] && pass "hq exit 3 fails closed as a structured Claude Stop block" || fail "hq error rc=$MRC"
assert_contains "$MERR" 'exited 3' "hq error stderr"
assert_contains "$MERR" 'simulated monitor-check failure' "hq error detail"
assert_contains "$MOUT" '"decision":"block"' "hq error block JSON"

reset_stub pass
run_master "$PAYLOAD_PASS" "$PATH_WITHOUT_HQ"
[ "$MRC" = "0" ] && pass "missing hq is loud and blocks Claude" || fail "missing hq rc=$MRC"
assert_contains "$MERR" 'hq CLI is missing' "missing hq stderr"
assert_contains "$MOUT" '"decision":"block"' "missing hq block JSON"

reset_stub blocked
run_master "$PAYLOAD_ACTIVE" "$PATH_WITH_HQ"
[ "$MRC" = "3" ] && pass "stop_hook_active avoids a second block" || fail "stop_hook_active rc=$MRC"
assert_empty "$MOUT" "stop_hook_active stdout"
assert_contains "$MERR" 'no second Stop block' "stop_hook_active warning"
assert_contains "$MERR" 'lane-a' "stop_hook_active remedy detail"

echo "[2] reminder shims are session-scoped and silent without active lanes"
REMINDER_PAYLOAD_SS='{"session_id":"senior-1","hook_event_name":"SessionStart","engine":"claude"}'
REMINDER_PAYLOAD_UPS='{"session_id":"senior-1","hook_event_name":"UserPromptSubmit","engine":"claude"}'
run_reminder() {
  local wrapper="$1" event="$2" engine="${3:-claude}" cache_home="${4:-$TMP/cache}" payload
  payload="$(jq -nc --arg ev "$event" --arg engine "$engine" '{session_id:"senior-1",hook_event_name:$ev,engine:$engine}')"
  RRC=0
  ROUT="$(printf '%s' "$payload" | env HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" \
    XDG_CACHE_HOME="$cache_home" PATH="$PATH_WITH_HQ" bash "$wrapper" "$event" \
    2>"$TMP/reminder-err")" || RRC=$?
  RERR="$(cat "$TMP/reminder-err")"
}

rm -rf "$TMP/cache"
reset_stub no-lanes
run_reminder "$WRAP_SS" SessionStart
[ "$RRC" = "0" ] && pass "not senior of a lane is silent" || fail "not-senior rc=$RRC stderr=$RERR"
assert_empty "$ROUT" "not-senior output"

rm -rf "$TMP/cache"
reset_stub terminal
run_reminder "$WRAP_UPS" UserPromptSubmit
[ "$RRC" = "0" ] && pass "terminal-only lanes are silent" || fail "terminal-only rc=$RRC stderr=$RERR"
assert_empty "$ROUT" "terminal-only output"

rm -rf "$TMP/cache"
reset_stub no-lanes
run_reminder "$WRAP_UPS" UserPromptSubmit codex
[ "$RRC" = "0" ] && pass "Codex reminder path passes" || fail "Codex reminder rc=$RRC stderr=$RERR"
assert_empty "$ROUT" "Codex reminder output"
contains "$(cat "$STUB_LOG")" '--engine codex' && pass "Codex reminder forwards engine" || fail "Codex reminder engine was not forwarded"

rm -rf "$TMP/cache"
reset_stub no-lanes
run_reminder "$WRAP_UPS" UserPromptSubmit grok
[ "$RRC" = "0" ] && pass "Grok reminder path passes" || fail "Grok reminder rc=$RRC stderr=$RERR"
assert_empty "$ROUT" "Grok reminder output"
contains "$(cat "$STUB_LOG")" '--engine grok' && pass "Grok reminder forwards engine" || fail "Grok reminder engine was not forwarded"

rm -rf "$TMP/cache"
reset_stub active-a
run_reminder "$WRAP_SS" SessionStart
[ "$RRC" = "0" ] && pass "active lane reminder exits 0" || fail "active lane rc=$RRC stderr=$RERR"
assert_contains "$ROUT" 'CLI-REMINDER' "active lane reminder text"
assert_contains "$ROUT" 'lane-a' "active lane id"
ACTIVE_CONTEXT="$(printf '%s' "$ROUT" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$ACTIVE_CONTEXT" 'Monitor(command="hq lanes watch lane-a"' "exact active Monitor call"
contains "$(cat "$STUB_LOG")" 'lanes monitor-check --session senior-1 --engine claude --json' \
  && pass "session-scoped JSON command is exact" || fail "session-scoped JSON command was not forwarded"
contains "$(cat "$STUB_ENV_LOG")" '1' && pass "reminder hq calls disable self-update" || fail "reminder did not disable self-update"
MONITOR_CACHE="$(monitor_cache_file "$TMP/cache")"
[ -n "$MONITOR_CACHE" ] && pass "monitor-check result cache is written" || fail "monitor-check result cache was not written"

PROMPT_CALLS_BEFORE="$(stub_call_count)"
run_reminder "$WRAP_UPS" UserPromptSubmit
[ "$RRC" = "0" ] && pass "cached prompt exits 0" || fail "cached prompt rc=$RRC stderr=$RERR"
assert_empty "$ROUT" "cached prompt output"
PROMPT_CALLS_AFTER="$(stub_call_count)"
[ "$PROMPT_CALLS_AFTER" = "$PROMPT_CALLS_BEFORE" ] \
  && pass "cached prompt does not launch hq" || fail "cached prompt launched hq"

SESSION_START_CALLS_BEFORE="$(stub_call_count)"
run_reminder "$WRAP_SS" SessionStart
[ "$RRC" = "0" ] && pass "SessionStart refresh exits 0" || fail "SessionStart refresh rc=$RRC stderr=$RERR"
assert_empty "$ROUT" "SessionStart refresh output"
SESSION_START_CALLS_AFTER="$(stub_call_count)"
[ "$SESSION_START_CALLS_AFTER" = "$((SESSION_START_CALLS_BEFORE + 1))" ] \
  && pass "SessionStart always launches hq" || fail "SessionStart reused the monitor cache"

MONITOR_CACHE="$(monitor_cache_file "$TMP/cache")"
make_monitor_cache_stale "$MONITOR_CACHE"
STALE_CALLS_BEFORE="$(stub_call_count)"
run_reminder "$WRAP_UPS" UserPromptSubmit
[ "$RRC" = "0" ] && pass "stale cache prompt exits 0" || fail "stale cache prompt rc=$RRC stderr=$RERR"
assert_empty "$ROUT" "stale cache prompt output"
STALE_CALLS_AFTER="$(stub_call_count)"
[ "$STALE_CALLS_AFTER" = "$((STALE_CALLS_BEFORE + 1))" ] \
  && pass "stale cache relaunches hq" || fail "stale cache did not relaunch hq"

UNCHANGED_LANE_CALLS_BEFORE="$(stub_call_count)"
run_reminder "$WRAP_UPS" UserPromptSubmit
[ "$RRC" = "0" ] && pass "refreshed seen lanes remain cacheable" || fail "refreshed seen lanes rc=$RRC stderr=$RERR"
assert_empty "$ROUT" "refreshed seen lanes output"
UNCHANGED_LANE_CALLS_AFTER="$(stub_call_count)"
[ "$UNCHANGED_LANE_CALLS_AFTER" = "$UNCHANGED_LANE_CALLS_BEFORE" ] \
  && pass "empty reminder cache avoids repeated hq launch" || fail "empty reminder cache relaunched hq"

make_monitor_cache_stale "$(monitor_cache_file "$TMP/cache")"
write_mode active-b
NEW_LANE_CALLS_BEFORE="$(stub_call_count)"
run_reminder "$WRAP_UPS" UserPromptSubmit
[ "$RRC" = "0" ] && pass "new lane after cache expiry exits 0" || fail "new lane after expiry rc=$RRC stderr=$RERR"
assert_contains "$ROUT" 'lane-b' "new lane after expiry id"
assert_not_contains "$ROUT" 'lane-a' "new lane after expiry does not repeat old lane"
NEW_LANE_CONTEXT="$(printf '%s' "$ROUT" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$NEW_LANE_CONTEXT" 'Monitor(command="hq lanes watch lane-b"' "exact new-lane Monitor call"
NEW_LANE_CALLS_AFTER="$(stub_call_count)"
[ "$NEW_LANE_CALLS_AFTER" = "$((NEW_LANE_CALLS_BEFORE + 2))" ] \
  && pass "new lane refresh launches monitor-check and reminder" || fail "new lane refresh call count was $NEW_LANE_CALLS_AFTER"

MONITOR_CACHE="$(monitor_cache_file "$TMP/cache")"
printf '%s\n' 'not-json' > "$MONITOR_CACHE"
write_mode active-b
UNREADABLE_CALLS_BEFORE="$(stub_call_count)"
run_reminder "$WRAP_UPS" UserPromptSubmit
[ "$RRC" = "0" ] && pass "unreadable cache refresh exits 0" || fail "unreadable cache rc=$RRC stderr=$RERR"
assert_empty "$ROUT" "unreadable cache output"
UNREADABLE_CALLS_AFTER="$(stub_call_count)"
[ "$UNREADABLE_CALLS_AFTER" = "$((UNREADABLE_CALLS_BEFORE + 1))" ] \
  && pass "unreadable cache refreshes hq" || fail "unreadable cache did not refresh hq"

rm -rf "$TMP/cache"
: > "$TMP/cache"
reset_stub no-lanes
run_reminder "$WRAP_SS" SessionStart
[ "$RRC" -ne 0 ] && pass "monitor cache write failure is non-zero" || fail "monitor cache write failure passed"
assert_empty "$ROUT" "monitor cache write failure output"
assert_contains "$RERR" 'monitor-check cache' "monitor cache write failure stderr"

rm -rf "$TMP/cache"
reset_stub no-lanes
RRC=0
ROUT="$(printf '%s' '{"session_id":"senior-1","hook_event_name":"SessionStart","engine":"claude"}' | \
  env HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" XDG_CACHE_HOME="$TMP/cache" PATH="$PATH_WITHOUT_HQ" \
  bash "$WRAP_SS" SessionStart 2>"$TMP/reminder-missing-err")" || RRC=$?
RERR="$(cat "$TMP/reminder-missing-err")"
[ "$RRC" -ne 0 ] && pass "missing hq reminder is non-zero" || fail "missing hq reminder passed"
assert_empty "$ROUT" "missing hq reminder output"
assert_contains "$RERR" 'hq CLI is missing' "missing hq reminder stderr"

rm -rf "$TMP/cache"
reset_stub error
run_reminder "$WRAP_UPS" UserPromptSubmit
[ "$RRC" -ne 0 ] && pass "monitor-check error is non-zero" || fail "monitor-check error passed"
assert_empty "$ROUT" "monitor-check error output"
assert_contains "$RERR" 'monitor-check --session returned exit 3' "monitor-check error stderr"

echo "[2b] master-hook sibling isolation"
SIBLING_FIX="$TMP/reminder-master"
mkdir -p "$SIBLING_FIX/.claude/hooks" "$SIBLING_FIX/core/hooks/SessionStart" \
  "$SIBLING_FIX/core/scripts/lib"
cp "$MASTER_SRC" "$SIBLING_FIX/.claude/hooks/master-hook.sh"
cp "$PROBE_SRC" "$SIBLING_FIX/.claude/hooks/hook-timeout-probe.sh"
cp "$GATE_SRC" "$SIBLING_FIX/.claude/hooks/hook-gate.sh"
cp "$FIX/.claude/hooks/hook-registry.json" "$SIBLING_FIX/.claude/hooks/hook-registry.json"
cp "$REMINDER_SRC" "$SIBLING_FIX/core/scripts/lib/lanes-senior-monitor.sh"
cp "$WRAP_SS" "$SIBLING_FIX/core/hooks/SessionStart/45-lanes-senior-monitor.sh"
cat > "$SIBLING_FIX/core/hooks/SessionStart/99-sibling.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
jq -nc '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:"SIBLING-OK"}}'
SH
chmod +x "$SIBLING_FIX/.claude/hooks/master-hook.sh" \
  "$SIBLING_FIX/core/hooks/SessionStart/45-lanes-senior-monitor.sh" \
  "$SIBLING_FIX/core/hooks/SessionStart/99-sibling.sh"
reset_stub no-lanes
MRC=0
MOUT="$(printf '%s' '{"session_id":"senior-1","hook_event_name":"SessionStart","engine":"claude"}' | \
  env HQ_ROOT="$SIBLING_FIX" CLAUDE_PROJECT_DIR="$SIBLING_FIX" HOME="$TMP/test-home" \
  HQ_ALLOW_HQ_WORKTREE=1 HQ_HOOK_TIMEOUT_SENTRY=0 PATH="$PATH_WITH_HQ" \
  bash "$SIBLING_FIX/.claude/hooks/master-hook.sh" SessionStart 2>"$TMP/sibling-err")" || MRC=$?
MERR="$(cat "$TMP/sibling-err")"
[ "$MRC" = "0" ] && pass "master preserves sibling with no active lanes" || fail "master sibling rc=$MRC stderr=$MERR"
assert_contains "$MOUT" 'SIBLING-OK' "master sibling output"
assert_not_contains "$MOUT" 'CLI-REMINDER' "master no-lane reminder silence"

echo "[2c] named master sibling mutation"
REM_MUT="$TMP/mutation-reminder-master-sibling.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/# ACTIVE_LANES_EMPTY_MUST_STAY_SILENT/{n;s/exit 0/exit 1;/;}' "$REM_MUT"
MUT_SIBLING_FIX="$TMP/reminder-master-mut"
mkdir -p "$MUT_SIBLING_FIX"
cp -R "$SIBLING_FIX/." "$MUT_SIBLING_FIX/"
cp "$REM_MUT" "$MUT_SIBLING_FIX/core/scripts/lib/lanes-senior-monitor.sh"
reset_stub no-lanes
MUT_MRC=0
MUT_MOUT="$(printf '%s' "$REMINDER_PAYLOAD_SS" | \
  env HQ_ROOT="$MUT_SIBLING_FIX" CLAUDE_PROJECT_DIR="$MUT_SIBLING_FIX" HOME="$TMP/test-home" \
  HQ_ALLOW_HQ_WORKTREE=1 HQ_HOOK_TIMEOUT_SENTRY=0 PATH="$PATH_WITH_HQ" \
  bash "$MUT_SIBLING_FIX/.claude/hooks/master-hook.sh" SessionStart 2>"$TMP/mut-sibling-err")" || MUT_MRC=$?
if [ "$MUT_MRC" = "0" ] && contains "$MUT_MOUT" 'SIBLING-OK'; then
  fail "mutation reminder_master_sibling did not go red"
else
  echo "MUTATION_RED: reminder_master_sibling / child failure isolation"
  pass "reminder_master_sibling"
fi

echo "[3] Codex/Grok adapter Stop dispatch forwards no-Monitor engines"
ADAPT="$TMP/adapter-fixture"
mkdir -p "$ADAPT/.claude/hooks" "$ADAPT/.codex/hooks" "$ADAPT/.grok/hooks" "$ADAPT/core/scripts/lib"
cp "$SRC/.codex/hooks/hq-codex-hook-adapter.sh" "$ADAPT/.codex/hooks/"
cp "$SRC/.grok/hooks/hq-grok-hook-adapter.sh" "$ADAPT/.grok/hooks/"
cp "$GATE_SRC" "$ADAPT/.claude/hooks/hook-gate.sh"
cp "$STOP_SRC" "$ADAPT/.claude/hooks/lanes-senior-monitor-stop-gate.sh"
cp "$SRC/core/scripts/hook-lib.sh" "$ADAPT/core/scripts/hook-lib.sh"
cp "$SRC/core/scripts/lib/hook-adapter-core.sh" "$ADAPT/core/scripts/lib/hook-adapter-core.sh"
jq -n '{hooks:{}}' > "$ADAPT/.claude/settings.json"
jq -n '{hooks:{Stop:[{matcher:"",hooks:[{id:"lanes-senior-monitor-stop-gate",script:".claude/hooks/lanes-senior-monitor-stop-gate.sh",timeout:30,gated:true}]}]}}' \
  > "$ADAPT/.claude/hooks/hook-registry.json"

reset_stub pass
ARC=0
AOUT="$(printf '%s' '{"hook_event_name":"Stop","session_id":"senior-1","cwd":"'"$ADAPT"'"}' | env HQ_ROOT="$ADAPT" CLAUDE_PROJECT_DIR="$ADAPT" HOME="$TMP/home" HQ_HOOK_TIMEOUT_SENTRY=0 PATH="$PATH_WITH_HQ" bash "$ADAPT/.codex/hooks/hq-codex-hook-adapter.sh")" || ARC=$?
[ "$ARC" = "0" ] && pass "Codex Stop adapter returns 0" || fail "Codex adapter rc=$ARC output=$AOUT"
contains "$(cat "$STUB_LOG")" '--engine codex' && pass "Codex adapter forwards --engine codex" || fail "Codex adapter did not forward engine"

reset_stub blocked
ARC=0
AOUT="$(printf '%s' '{"hook_event_name":"Stop","session_id":"senior-1","cwd":"'"$ADAPT"'"}' | env HQ_ROOT="$ADAPT" CLAUDE_PROJECT_DIR="$ADAPT" HOME="$TMP/home" HQ_HOOK_TIMEOUT_SENTRY=0 PATH="$PATH_WITH_HQ" bash "$ADAPT/.codex/hooks/hq-codex-hook-adapter.sh")" || ARC=$?
[ "$ARC" = "0" ] && pass "Codex uncovered lanes remain advisory" || fail "Codex uncovered lanes rc=$ARC output=$AOUT"
assert_empty "$AOUT" "Codex uncovered lanes do not emit a Claude block"

reset_stub pass
ARC=0
AOUT="$(printf '%s' '{"hookEventName":"Stop","sessionId":"senior-1","cwd":"'"$ADAPT"'"}' | env HQ_ROOT="$ADAPT" CLAUDE_PROJECT_DIR="$ADAPT" HOME="$TMP/home" HQ_HOOK_TIMEOUT_SENTRY=0 PATH="$PATH_WITH_HQ" bash "$ADAPT/.grok/hooks/hq-grok-hook-adapter.sh")" || ARC=$?
[ "$ARC" = "0" ] && pass "Grok Stop adapter returns 0" || fail "Grok adapter rc=$ARC output=$AOUT"
contains "$(cat "$STUB_LOG")" '--engine grok' && pass "Grok adapter forwards --engine grok" || fail "Grok adapter did not forward engine"

reset_stub blocked
ARC=0
AOUT="$(printf '%s' '{"hookEventName":"Stop","sessionId":"senior-1","cwd":"'"$ADAPT"'"}' | env HQ_ROOT="$ADAPT" CLAUDE_PROJECT_DIR="$ADAPT" HOME="$TMP/home" HQ_HOOK_TIMEOUT_SENTRY=0 PATH="$PATH_WITH_HQ" bash "$ADAPT/.grok/hooks/hq-grok-hook-adapter.sh")" || ARC=$?
[ "$ARC" = "0" ] && pass "Grok uncovered lanes remain advisory" || fail "Grok uncovered lanes rc=$ARC output=$AOUT"
assert_empty "$AOUT" "Grok uncovered lanes do not emit a Claude block"

echo "[4] Stop registry sequencing preserves later security reasons"
assert_stop_order() {
  jq -e '
    .hooks.Stop[0].hooks | map(.id) as $ids
    | (($ids | index("lanes-senior-monitor-stop-gate")) > ($ids | index("enforce-capability-link-render")))
      and (($ids | index("lanes-senior-monitor-stop-gate")) > ($ids | index("enforce-humanize-before-send")))
      and (($ids | index("lanes-senior-monitor-stop-gate")) > ($ids | index("conduct-lane-inbox")))
  ' "$1" >/dev/null 2>&1
}
if assert_stop_order "$REGISTRY_SRC"; then
  pass "lane Stop hook runs after later security guards"
else
  fail "lane Stop hook ordering does not preserve later security guards"
fi
REGISTRY_MUT="$TMP/mutation-stop-order.json"
jq '
  .hooks.Stop[0].hooks = ([.hooks.Stop[0].hooks[] | select(.id == "lanes-senior-monitor-stop-gate")] + [.hooks.Stop[0].hooks[] | select(.id != "lanes-senior-monitor-stop-gate")])
' "$REGISTRY_SRC" > "$REGISTRY_MUT"
if assert_stop_order "$REGISTRY_MUT"; then
  fail "mutation stop_order did not go red"
else
  echo "MUTATION_RED: stop_order / lane gate before later security guards"
  pass "stop_order"
fi

echo "[5] Named mutations are watched red"
mutate_and_run() {
  local name="$1" source="$2" payload="$3" path_env="$4" engine="$5"; shift 5
  local mut="$TMP/mutation-$name.sh"
  cp "$source" "$mut"
  "$@" "$mut"
  run_direct "$mut" "$payload" "$path_env" "$engine"
}

REM_MUT="$TMP/mutation-monitor-cache-hit.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/# CACHE_HIT_MUST_SKIP_MONITOR_CHECK/{n;s/-eq 0/-eq 1/;}' "$REM_MUT"
rm -rf "$TMP/direct-cache"
reset_stub active-a
run_direct "$REMINDER_SRC" "$REMINDER_PAYLOAD_SS" "$PATH_WITH_HQ" claude
CACHE_HIT_CALLS_BEFORE="$(stub_call_count)"
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_UPS" "$PATH_WITH_HQ" claude
CACHE_HIT_CALLS_AFTER="$(stub_call_count)"
if [ "$CACHE_HIT_CALLS_AFTER" = "$CACHE_HIT_CALLS_BEFORE" ]; then
  fail "mutation monitor_cache_hit did not go red"
else
  echo "MUTATION_RED: monitor_cache_hit / warm UserPromptSubmit must skip hq"
  pass "monitor_cache_hit"
fi

REM_MUT="$TMP/mutation-monitor-cache-reminder.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/# CACHE_HIT_MUST_REUSE_REMINDER/{n;s/-eq 1/-eq 0/;}' "$REM_MUT"
rm -rf "$TMP/direct-cache"
reset_stub active-a
run_direct "$REMINDER_SRC" "$REMINDER_PAYLOAD_SS" "$PATH_WITH_HQ" claude
rm -f "$TMP/direct-cache/hq-cli/lanes-senior-monitor/senior-1.seen.json"
CACHE_REMINDER_CALLS_BEFORE="$(stub_call_count)"
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_UPS" "$PATH_WITH_HQ" claude
CACHE_REMINDER_CALLS_AFTER="$(stub_call_count)"
if [ "$CACHE_REMINDER_CALLS_AFTER" = "$CACHE_REMINDER_CALLS_BEFORE" ]; then
  fail "mutation monitor_cache_reminder did not go red"
else
  echo "MUTATION_RED: monitor_cache_reminder / warm prompt must reuse reminder text"
  pass "monitor_cache_reminder"
fi

REM_MUT="$TMP/mutation-monitor-cache-stale.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/# STALE_CACHE_MUST_REFRESH/{n;s/-lt/-ge/;}' "$REM_MUT"
rm -rf "$TMP/direct-cache"
reset_stub active-a
run_direct "$REMINDER_SRC" "$REMINDER_PAYLOAD_SS" "$PATH_WITH_HQ" claude
make_monitor_cache_stale "$(monitor_cache_file "$TMP/direct-cache")"
CACHE_STALE_CALLS_BEFORE="$(stub_call_count)"
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_UPS" "$PATH_WITH_HQ" claude
CACHE_STALE_CALLS_AFTER="$(stub_call_count)"
if [ "$CACHE_STALE_CALLS_AFTER" = "$CACHE_STALE_CALLS_BEFORE" ]; then
  echo "MUTATION_RED: monitor_cache_stale / stale result must relaunch hq"
  pass "monitor_cache_stale"
else
  fail "mutation monitor_cache_stale did not go red"
fi

REM_MUT="$TMP/mutation-monitor-cache-no-new-lane.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/or (\.reminder | type) != "string"/a\      or (((.result.uncovered_lane_ids | length) > 0) and ((.reminder | length) == 0))' "$REM_MUT"
rm -rf "$TMP/direct-cache"
reset_stub active-a
run_direct "$REMINDER_SRC" "$REMINDER_PAYLOAD_SS" "$PATH_WITH_HQ" claude
make_monitor_cache_stale "$(monitor_cache_file "$TMP/direct-cache")"
run_direct "$REMINDER_SRC" "$REMINDER_PAYLOAD_UPS" "$PATH_WITH_HQ" claude
NO_NEW_LANE_CALLS_BEFORE="$(stub_call_count)"
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_UPS" "$PATH_WITH_HQ" claude
NO_NEW_LANE_CALLS_AFTER="$(stub_call_count)"
if [ "$NO_NEW_LANE_CALLS_AFTER" = "$NO_NEW_LANE_CALLS_BEFORE" ]; then
  fail "mutation monitor_cache_no_new_lane did not go red"
else
  echo "MUTATION_RED: monitor_cache_no_new_lane / empty reminder refresh must remain valid"
  pass "monitor_cache_no_new_lane"
fi

REM_MUT="$TMP/mutation-monitor-cache-session-start.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/# SESSION_START_MUST_BYPASS_CACHE/{n;s/|| return 0/\&\& return 0/;}' "$REM_MUT"
rm -rf "$TMP/direct-cache"
reset_stub active-a
run_direct "$REMINDER_SRC" "$REMINDER_PAYLOAD_SS" "$PATH_WITH_HQ" claude
CACHE_SESSION_START_CALLS_BEFORE="$(stub_call_count)"
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_SS" "$PATH_WITH_HQ" claude
CACHE_SESSION_START_CALLS_AFTER="$(stub_call_count)"
if [ "$CACHE_SESSION_START_CALLS_AFTER" = "$CACHE_SESSION_START_CALLS_BEFORE" ]; then
  echo "MUTATION_RED: monitor_cache_session_start / SessionStart must refresh"
  pass "monitor_cache_session_start"
else
  fail "mutation monitor_cache_session_start did not go red"
fi

REM_MUT="$TMP/mutation-monitor-cache-new-lane.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i 's/--argjson new "$NEW_UNCOVERED_IDS"/--argjson new "[]"/' "$REM_MUT"
rm -rf "$TMP/direct-cache"
reset_stub active-a
run_direct "$REMINDER_SRC" "$REMINDER_PAYLOAD_SS" "$PATH_WITH_HQ" claude
make_monitor_cache_stale "$(monitor_cache_file "$TMP/direct-cache")"
write_mode active-b
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_UPS" "$PATH_WITH_HQ" claude
if [ "$DRC" = "0" ] && contains "$DOUT" 'lane-b'; then
  fail "mutation monitor_cache_new_lane did not go red"
else
  echo "MUTATION_RED: monitor_cache_new_lane / expired cache must recommend new lane"
  pass "monitor_cache_new_lane"
fi

REM_MUT="$TMP/mutation-monitor-cache-unreadable.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/# STALE_OR_UNREADABLE_CACHE_MUST_REFRESH/{n;s/return 0/CACHE_HIT=1; return 0/;}' "$REM_MUT"
rm -rf "$TMP/direct-cache"
reset_stub active-a
run_direct "$REMINDER_SRC" "$REMINDER_PAYLOAD_SS" "$PATH_WITH_HQ" claude
printf '%s\n' 'not-json' > "$(monitor_cache_file "$TMP/direct-cache")"
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_UPS" "$PATH_WITH_HQ" claude
if [ "$DRC" = "0" ] && [ -z "$DOUT" ]; then
  fail "mutation monitor_cache_unreadable did not go red"
else
  echo "MUTATION_RED: monitor_cache_unreadable / unreadable cache must refresh"
  pass "monitor_cache_unreadable"
fi

REM_MUT="$TMP/mutation-monitor-cache-write.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/# MONITOR_CACHE_WRITE_MUST_FAIL_LOUDLY/{n;s/write_monitor_cache "$reminder" || exit 1/write_monitor_cache "$reminder" || true/;}' "$REM_MUT"
rm -rf "$TMP/direct-cache"
: > "$TMP/direct-cache"
reset_stub no-lanes
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_SS" "$PATH_WITH_HQ" claude
if [ "$DRC" -ne 0 ]; then
  fail "mutation monitor_cache_write did not go red"
else
  echo "MUTATION_RED: monitor_cache_write / cache failure must remain loud"
  pass "monitor_cache_write"
fi

REM_MUT="$TMP/mutation-reminder-no-senior.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/# ACTIVE_LANES_EMPTY_MUST_STAY_SILENT/{n;s/exit 0/exit 1;/;}' "$REM_MUT"
rm -rf "$TMP/direct-cache"
write_mode no-lanes
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_SS" "$PATH_WITH_HQ" claude
if [ "$DRC" = "0" ] && [ -z "$DOUT" ] && [ -z "$DERR" ]; then
  fail "mutation reminder_no_senior did not go red"
else
  echo "MUTATION_RED: reminder_no_senior / empty active lane set"
  pass "reminder_no_senior"
fi

REM_MUT="$TMP/mutation-reminder-terminal-only.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/# ACTIVE_LANES_EMPTY_MUST_STAY_SILENT/{n;s/exit 0/exit 1;/;}' "$REM_MUT"
rm -rf "$TMP/direct-cache"
write_mode terminal
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_UPS" "$PATH_WITH_HQ" claude
if [ "$DRC" = "0" ] && [ -z "$DOUT" ] && [ -z "$DERR" ]; then
  fail "mutation reminder_terminal_only did not go red"
else
  echo "MUTATION_RED: reminder_terminal_only / terminal active-lane filter"
  pass "reminder_terminal_only"
fi

REM_MUT="$TMP/mutation-reminder-active.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/# ACTIVE_LANE_REMINDER_RETURN/{n;s/jq -nc/: # mutated active reminder/;}' "$REM_MUT"
rm -rf "$TMP/direct-cache"
write_mode active-a
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_SS" "$PATH_WITH_HQ" claude
if [ "$DRC" = "0" ] && contains "$DOUT" 'lane-a'; then
  fail "mutation reminder_active did not go red"
else
  echo "MUTATION_RED: reminder_active / active-lane additionalContext"
  pass "reminder_active"
fi

REM_MUT="$TMP/mutation-reminder-repeat.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/# SEEN_LANE_MUST_SUPPRESS_REPEATS/{n;s/exit 0/exit 1;/;}' "$REM_MUT"
rm -rf "$TMP/direct-cache"
write_mode active-a
run_direct "$REMINDER_SRC" "$REMINDER_PAYLOAD_SS" "$PATH_WITH_HQ" claude
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_UPS" "$PATH_WITH_HQ" claude
if [ "$DRC" = "0" ] && [ -z "$DOUT" ] && [ -z "$DERR" ]; then
  fail "mutation reminder_repeat did not go red"
else
  echo "MUTATION_RED: reminder_repeat / per-session seen lane cache"
  pass "reminder_repeat"
fi

REM_MUT="$TMP/mutation-reminder-new-lane.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i 's/--argjson new "$NEW_UNCOVERED_IDS"/--argjson new "[]"/' "$REM_MUT"
rm -rf "$TMP/direct-cache"
write_mode active-a
run_direct "$REMINDER_SRC" "$REMINDER_PAYLOAD_SS" "$PATH_WITH_HQ" claude
write_mode active-b
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_UPS" "$PATH_WITH_HQ" claude
if [ "$DRC" = "0" ] && contains "$DOUT" 'lane-b' && ! contains "$DOUT" 'lane-a'; then
  fail "mutation reminder_new_lane did not go red"
else
  echo "MUTATION_RED: reminder_new_lane / new lane Monitor recommendation"
  pass "reminder_new_lane"
fi

REM_MUT="$TMP/mutation-reminder-missing-hq.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/# MISSING_HQ_MUST_STAY_STDERR_ONLY/{n;s/printf /: # mutated missing hq /;}' "$REM_MUT"
rm -rf "$TMP/direct-cache"
write_mode no-lanes
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_SS" "$PATH_WITHOUT_HQ" claude
if [ "$DRC" = "0" ] || [ -n "$DOUT" ] || contains "$DERR" 'hq CLI is missing'; then
  fail "mutation reminder_missing_hq did not go red"
else
  echo "MUTATION_RED: reminder_missing_hq / stderr-only failure"
  pass "reminder_missing_hq"
fi

REM_MUT="$TMP/mutation-reminder-monitor-error.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i '/# MONITOR_CHECK_ERROR_MUST_STAY_STDERR_ONLY/{n;s/report_hq_error /: # mutated monitor error /;}' "$REM_MUT"
rm -rf "$TMP/direct-cache"
write_mode error
run_direct "$REM_MUT" "$REMINDER_PAYLOAD_UPS" "$PATH_WITH_HQ" claude
if [ "$DRC" -ne 0 ] && [ -z "$DOUT" ] && contains "$DERR" 'monitor-check --session returned exit 3'; then
  fail "mutation reminder_monitor_error did not go red"
else
  echo "MUTATION_RED: reminder_monitor_error / stderr-only CLI error"
  pass "reminder_monitor_error"
fi

write_mode blocked
mutate_and_run blocked_exit "$STOP_SRC" "$PAYLOAD_PASS" "$PATH_WITH_HQ" claude \
  sed -i '/# UNCOVERED_BLOCK_RETURN/{n;s/return 0/return 2;/;}'
write_mode blocked
if [ "$DRC" = "0" ]; then fail "mutation blocked_exit did not go red"; else echo "MUTATION_RED: blocked_exit / uncovered block return"; pass "blocked_exit"; fi

write_mode pass
mutate_and_run pass_exit "$STOP_SRC" "$PAYLOAD_PASS" "$PATH_WITH_HQ" claude \
  sed -i '/# PASS_RESULT_RETURN/{n;s/exit 0/exit 2;/;}'
if [ "$DRC" = "0" ] && [ -z "$DOUT" ] && [ -z "$DERR" ]; then fail "mutation pass_exit did not go red"; else echo "MUTATION_RED: pass_exit / success return"; pass "pass_exit"; fi

write_mode error
mutate_and_run error_fail_open "$STOP_SRC" "$PAYLOAD_PASS" "$PATH_WITH_HQ" claude \
  sed -i '/# CLAUDE_ERROR_FAIL_CLOSED_RETURN/{n;s/return 0/return 2;/;}'
if [ "$DRC" = "0" ]; then fail "mutation error_fail_open did not go red"; else echo "MUTATION_RED: error_fail_open / Claude error block"; pass "error_fail_open"; fi

write_mode pass
mutate_and_run missing_hq "$STOP_SRC" "$PAYLOAD_PASS" "$PATH_WITHOUT_HQ" claude \
  sed -i '/# MISSING_HQ_MUST_ERROR/{n;s/gate_error /: # mutated missing hq /;}'
if [ -n "$DOUT" ] && [ "$DRC" = "0" ]; then fail "mutation missing_hq did not go red"; else echo "MUTATION_RED: missing_hq / missing CLI status"; pass "missing_hq"; fi

write_mode blocked
mutate_and_run active_block "$STOP_SRC" "$PAYLOAD_ACTIVE" "$PATH_WITH_HQ" claude \
  sed -i '/# ACTIVE_STOP_MUST_NOT_BLOCK/{n;s/return 3/return 2;/;}'
if [ "$DRC" = "3" ] && [ -z "$DOUT" ]; then fail "mutation active_block did not go red"; else echo "MUTATION_RED: active_block / recursion guard"; pass "active_block"; fi

write_mode pass
mutate_and_run engine_forward "$STOP_SRC" "$PAYLOAD_PASS" "$PATH_WITH_HQ" codex \
  sed -i 's/--engine "\$ENGINE"/--engine claude/'
if contains "$(cat "$STUB_LOG")" '--engine codex'; then fail "mutation engine_forward did not go red"; else echo "MUTATION_RED: engine_forward / adapter engine argument"; pass "engine_forward"; fi

TIMEOUT_TEST="$TMP/timeout-test.sh"
cp "$STOP_SRC" "$TIMEOUT_TEST"
sed -i 's/LANES_MONITOR_CHECK_TIMEOUT_SECONDS=20/LANES_MONITOR_CHECK_TIMEOUT_SECONDS=1/' "$TIMEOUT_TEST"
write_mode hang
run_direct "$TIMEOUT_TEST" "$PAYLOAD_PASS" "$PATH_WITH_HQ" claude
if [ "$DRC" = "0" ] && contains "$DOUT" '"decision":"block"' && contains "$DERR" 'timed out'; then
  echo "MUTATION_RED: inner_timeout / hq timeout fails closed"
  pass "inner_timeout"
else
  fail "inner timeout did not produce a structured fail-closed block: rc=$DRC stdout=$DOUT stderr=$DERR"
fi
TIMEOUT_MUT="$TMP/mutation-inner-timeout.sh"
cp "$TIMEOUT_TEST" "$TIMEOUT_MUT"
sed -i '/# INNER_TIMEOUT_MUST_FAIL_CLOSED/{n;s/gate_error /: # mutated timeout /;}' "$TIMEOUT_MUT"
run_direct "$TIMEOUT_MUT" "$PAYLOAD_PASS" "$PATH_WITH_HQ" claude
if contains "$DOUT" '"decision":"block"'; then
  fail "mutation inner_timeout did not go red"
else
  echo "MUTATION_RED: inner_timeout / timeout fail-closed branch"
  pass "inner_timeout_guard"
fi

REM_MUT="$TMP/mutation-reminder.sh"
cp "$REMINDER_SRC" "$REM_MUT"
sed -i 's/--reminder/--help/' "$REM_MUT"
reset_stub active-a
rm -rf "$TMP/cache"
RRC=0
ROUT="$(printf '%s' "$REMINDER_PAYLOAD_SS" | env HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" XDG_CACHE_HOME="$TMP/cache" PATH="$PATH_WITH_HQ" bash "$REM_MUT" SessionStart 2>"$TMP/reminder-mut-err")" || RRC=$?
if contains "$ROUT" 'CLI-REMINDER'; then fail "mutation reminder_command did not go red"; else echo "MUTATION_RED: reminder_command / --reminder forwarding"; pass "reminder_command"; fi

if [ "$FAIL" -eq 0 ]; then
  echo "ALL PASS: lanes-senior-monitor-stop-gate"
  exit 0
fi
echo "lanes-senior-monitor-stop-gate: $FAIL failure(s)" >&2
exit 1
