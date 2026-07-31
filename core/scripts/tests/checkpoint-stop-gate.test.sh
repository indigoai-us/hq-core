#!/usr/bin/env bash
# Regression tests for the checkpoint Stop gate. The released CLI intentionally
# is not used here: a local shim supplies the gate-probe contract.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/checkpoint-stop-gate.sh"
BASH_BIN="$(command -v bash)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok — $*"; }

assert_empty() {
  local value="$1"
  local label="$2"
  [ -z "$value" ] || fail "$label: expected empty stdout, got: $value"
}

assert_block() {
  local value="$1"
  local session="$2"
  local label="$3"
  printf '%s' "$value" | grep -q '"decision":"block"' || fail "$label: no block decision: $value"
  printf '%s' "$value" | grep -qF "$session" || fail "$label: session id missing from reason: $value"
}

[ -x "$HOOK" ] || fail "checkpoint Stop hook is not executable: $HOOK"

FIXTURE="$TMP_ROOT/hq"
STATE_DIR="$FIXTURE/workspace/orchestrator/hook-state"
SHIM_DIR="$TMP_ROOT/shim-bin"
NO_HQ_DIR="$TMP_ROOT/no-hq-bin"
SHIM_LOG="$TMP_ROOT/hq-shim.log"
mkdir -p "$FIXTURE/.claude/hooks" "$FIXTURE/core/scripts" "$STATE_DIR" "$SHIM_DIR" "$NO_HQ_DIR"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIXTURE/core/scripts/hook-lib.sh"
cp "$HOOK" "$FIXTURE/.claude/hooks/checkpoint-stop-gate.sh"
chmod +x "$FIXTURE/.claude/hooks/checkpoint-stop-gate.sh"

cat >"$SHIM_DIR/hq" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$HQ_SHIM_LOG"
if [ "${1:-}" = "core" ] && [ "${2:-}" = "checkpoint" ] && [ "${3:-}" = "--gate-probe" ]; then
  mkdir -p "$HQ_SHIM_ROOT/workspace/orchestrator/hook-state"
  printf '%s' "${HQ_SHIM_VERDICT:-1}" >"$HQ_SHIM_ROOT/workspace/orchestrator/hook-state/checkpoint-gate-eligible"
fi
SHIM
chmod +x "$SHIM_DIR/hq"

# A deliberately hq-free PATH lets the missing-CLI case be deterministic even
# on developer machines that have an unrelated hq binary installed.
for tool in cat jq mkdir tail tr date stat cksum awk rm; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$tool_path" ] || fail "required test utility is unavailable: $tool"
  ln -s "$tool_path" "$NO_HQ_DIR/$tool"
done

append_user() {
  local transcript="$1"
  local uuid="$2"
  printf '{"type":"user","uuid":"%s","message":{"content":"prompt"}}\n' "$uuid" >>"$transcript"
}

append_tool() {
  local transcript="$1"
  local id="$2"
  local name="$3"
  local command="$4"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"%s","name":"%s","input":{"command":"%s"}}]}}\n' \
    "$id" "$name" "$command" >>"$transcript"
}

append_result() {
  local transcript="$1"
  local id="$2"
  local is_error="$3"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s","is_error":%s}]}}\n' \
    "$id" "$is_error" >>"$transcript"
}

new_transcript() {
  local label="$1"
  TRANSCRIPT="$TMP_ROOT/$label.jsonl"
  : >"$TRANSCRIPT"
}

set_verdict() {
  local verdict="$1"
  printf '%s' "$verdict" >"$STATE_DIR/checkpoint-gate-eligible"
}

clear_verdict() {
  rm -f "$STATE_DIR/checkpoint-gate-eligible"
}

reset_case() {
  rm -f "$STATE_DIR"/stop-gate-blocks-* "$SHIM_LOG"
  RUN_PATH="$SHIM_DIR:$PATH"
  RUN_GATE=""
  RUN_SIBLING=""
}

run_hook() {
  local session="$1"
  local transcript="$2"
  local stderr_path="$TMP_ROOT/hook.stderr"
  local payload
  payload="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false,"cwd":"%s"}' "$session" "$transcript" "$FIXTURE")"
  HOOK_STDERR=""
  HOOK_STDOUT="$(env \
    "CLAUDE_PROJECT_DIR=$FIXTURE" \
    "HQ_SHIM_LOG=$SHIM_LOG" \
    "HQ_SHIM_ROOT=$FIXTURE" \
    "HQ_SHIM_VERDICT=1" \
    "HQ_CHECKPOINT_GATE=$RUN_GATE" \
    "HQ_CHECKPOINT_SIBLING=$RUN_SIBLING" \
    "PATH=$RUN_PATH" \
    "$BASH_BIN" "$FIXTURE/.claude/hooks/checkpoint-stop-gate.sh" <<<"$payload" 2>"$stderr_path")"
  HOOK_STATUS=$?
  HOOK_STDERR="$(cat "$stderr_path")"
}

wait_for_probe() {
  local label="$1"
  local attempts=0
  while [ "$attempts" -lt 40 ]; do
    if grep -q -- '--gate-probe' "$SHIM_LOG" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
    attempts=$((attempts + 1))
  done
  fail "$label: shim did not receive --gate-probe"
}

assert_allow() {
  local label="$1"
  [ "$HOOK_STATUS" -eq 0 ] || fail "$label: expected exit 0, got $HOOK_STATUS"
  assert_empty "$HOOK_STDOUT" "$label"
}

# 1. Eligible, final successful checkpoint call.
reset_case
set_verdict 1
new_transcript 1-ok
append_user "$TRANSCRIPT" u-ok
append_tool "$TRANSCRIPT" tu-1 Bash 'hq core checkpoint --idle'
append_result "$TRANSCRIPT" tu-1 false
run_hook s-ok "$TRANSCRIPT"
assert_allow "successful final checkpoint"
pass "successful final checkpoint allows"

# 2. Eligible tool turn without a checkpoint.
reset_case
set_verdict 1
new_transcript 2-missing
append_user "$TRANSCRIPT" u-missing
append_tool "$TRANSCRIPT" tu-2 Bash 'git status'
append_result "$TRANSCRIPT" tu-2 false
run_hook s-missing "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-missing "missing checkpoint"
pass "missing checkpoint blocks"

# 3. A later tool invalidates an otherwise valid checkpoint.
reset_case
set_verdict 1
new_transcript 3-later-tool
append_user "$TRANSCRIPT" u-later-tool
append_tool "$TRANSCRIPT" tu-3a Bash 'hq core checkpoint --idle'
append_result "$TRANSCRIPT" tu-3a false
append_tool "$TRANSCRIPT" tu-3b Bash 'git status'
append_result "$TRANSCRIPT" tu-3b false
run_hook s-later-tool "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-later-tool "later tool after checkpoint"
pass "later tool after checkpoint blocks"

# 4. A failed checkpoint does not satisfy the gate.
reset_case
set_verdict 1
new_transcript 4-failed-checkpoint
append_user "$TRANSCRIPT" u-failed-checkpoint
append_tool "$TRANSCRIPT" tu-4 Bash 'hq core checkpoint --idle'
append_result "$TRANSCRIPT" tu-4 true
run_hook s-failed-checkpoint "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-failed-checkpoint "failed checkpoint"
pass "failed checkpoint blocks"

# 5. Environment-prefixed checkpoint invocations count.
reset_case
set_verdict 1
new_transcript 5-env-prefix
append_user "$TRANSCRIPT" u-env-prefix
append_tool "$TRANSCRIPT" tu-5 Bash 'HQ_ROOT=/x hq core checkpoint --idle'
append_result "$TRANSCRIPT" tu-5 false
run_hook s-env-prefix "$TRANSCRIPT"
assert_allow "environment-prefixed checkpoint"
pass "environment-prefixed checkpoint allows"

# 6. Ineligible identities are completely unaffected.
reset_case
set_verdict 0
new_transcript 6-ineligible
append_user "$TRANSCRIPT" u-ineligible
append_tool "$TRANSCRIPT" tu-6 Bash 'git status'
run_hook s-ineligible "$TRANSCRIPT"
assert_allow "ineligible verdict"
pass "verdict 0 allows"

# 7. A missing verdict allows now and refreshes in the background.
reset_case
clear_verdict
new_transcript 7-refresh
append_user "$TRANSCRIPT" u-refresh
append_tool "$TRANSCRIPT" tu-7 Bash 'git status'
run_hook s-refresh "$TRANSCRIPT"
assert_allow "missing verdict"
wait_for_probe "missing verdict"
pass "missing verdict refreshes asynchronously"

# 8. Missing hq is an allow path and remains quiet.
reset_case
clear_verdict
RUN_PATH="$NO_HQ_DIR"
new_transcript 8-no-hq
append_user "$TRANSCRIPT" u-no-hq
append_tool "$TRANSCRIPT" tu-8 Bash 'git status'
run_hook s-no-hq "$TRANSCRIPT"
assert_allow "missing hq"
assert_empty "$HOOK_STDERR" "missing hq"
pass "missing hq allows quietly"

# 9. Two blocks per turn are enough; the third Stop invocation gives up.
reset_case
set_verdict 1
new_transcript 9-loop-cap
append_user "$TRANSCRIPT" u-loop-cap
append_tool "$TRANSCRIPT" tu-9 Bash 'git status'
run_hook s-loop-cap "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-loop-cap "loop cap first block"
run_hook s-loop-cap "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-loop-cap "loop cap second block"
run_hook s-loop-cap "$TRANSCRIPT"
assert_allow "loop cap third invocation"
pass "loop cap allows the third evaluation"

# 10. The checkpoint sibling must never recursively gate itself.
reset_case
set_verdict 1
RUN_SIBLING=1
new_transcript 10-sibling
append_user "$TRANSCRIPT" u-sibling
run_hook s-sibling "$TRANSCRIPT"
assert_allow "checkpoint sibling"
pass "checkpoint sibling allows"

# 11. Operator opt-out wins over a positive verdict.
reset_case
set_verdict 1
RUN_GATE=0
new_transcript 11-gate-off
append_user "$TRANSCRIPT" u-gate-off
run_hook s-gate-off "$TRANSCRIPT"
assert_allow "HQ_CHECKPOINT_GATE=0"
pass "HQ_CHECKPOINT_GATE=0 allows"

# 12. Force-enforce skips the verdict cache.
reset_case
clear_verdict
RUN_GATE=1
new_transcript 12-force
append_user "$TRANSCRIPT" u-force
append_tool "$TRANSCRIPT" tu-12 Bash 'git status'
run_hook s-force "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-force "HQ_CHECKPOINT_GATE=1"
pass "HQ_CHECKPOINT_GATE=1 enforces without verdict"

# 13. A stale positive verdict still enforces and asks the shim to refresh.
reset_case
set_verdict 1
touch -d '25 hours ago' "$STATE_DIR/checkpoint-gate-eligible"
new_transcript 13-stale
append_user "$TRANSCRIPT" u-stale
append_tool "$TRANSCRIPT" tu-13 Bash 'git status'
run_hook s-stale "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-stale "stale verdict"
wait_for_probe "stale verdict"
pass "stale verdict enforces and refreshes"

# 14. A pure Q&A turn also needs the explicit --idle checkpoint.
reset_case
set_verdict 1
new_transcript 14-no-tools
append_user "$TRANSCRIPT" u-no-tools
run_hook s-no-tools "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-no-tools "turn without tools"
pass "tool-free turn blocks"

# 15. An unreadable or missing transcript is always an allow path.
reset_case
set_verdict 1
run_hook s-missing-transcript "$TMP_ROOT/does-not-exist.jsonl"
assert_allow "missing transcript"
mkdir "$TMP_ROOT/not-a-transcript"
run_hook s-unusable-transcript "$TMP_ROOT/not-a-transcript"
assert_allow "unusable transcript path"
pass "missing or unusable transcript allows"

# 16. Registration is routed through hook-gate and all profiles contain it.
grep -qF 'hook-gate.sh\" checkpoint-stop-gate \"$CLAUDE_PROJECT_DIR/.claude/hooks/checkpoint-stop-gate.sh\"' \
  "$ROOT/.claude/settings.json" || fail "settings.json has no checkpoint Stop-gate registration"
for profile in standard strict; do
  profile_body="$(sed -n "/is_in_${profile}_profile()/,/^}/p" "$ROOT/.claude/hooks/hook-gate.sh")"
  printf '%s' "$profile_body" | grep -q 'checkpoint-stop-gate' || fail "$profile hook profile omits checkpoint-stop-gate"
done
[ -x "$HOOK" ] || fail "checkpoint Stop hook is not executable"
pass "registration and profile membership are present"

echo "checkpoint Stop gate: ok"
