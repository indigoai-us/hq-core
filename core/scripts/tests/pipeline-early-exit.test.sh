#!/usr/bin/env bash
# pipeline-driver.sh: early engine exit on a phase (engine_exited_early).
#
# No lanes and no engine: the state dir is written by hand, the pool is a stub
# that lists one loop lane (with a run dir whose journal.jsonl the test writes)
# and answers every assign with an enqueue, so the conductor re-routes a phase
# without starting anything.
#
# Case 1: no handoff, the lane journalled phase-exit -> EARLY_EXIT tick line with
#   story, phase and elapsed time; a failed handoff with exit_reason is accepted
#   and the phase is routed again (the one restart in place).
# Case 2: a second phase-exit after the re-route -> held for the owner, exit 21
#   naming engine_exited_early, decision item names it.
# Case 3: a handoff whose status is not terminal plus a phase-exit -> early exit.
# Case 4: a non-terminal handoff and no phase-exit (engine still running) -> not
#   accepted, no early exit, the driver keeps waiting (deadline path unchanged).
# bash 3.2 portable.
set -u
unset HQ_SPAWN_COMPANY HQ_PARENT_SESSION_ID HQ_PIPELINE_DECISIONS_FILE HQ_WORKFLOW_LANE \
  CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID \
  PC_WORKERS_ROOT PC_POOL PC_ENVELOPE PC_NOW PC_MAX_STORIES PIPELINE_DRIVER_POOL
# Isolation: its own session id and HQ root; the stub pool never reaches a real one.
export HQ_SESSION_ID="test-pipeline-early-exit-$$"

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
DRIVER="${PIPELINE_EARLY_DRIVER:-$SCRIPTS/pipeline-driver.sh}"

pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
wait_for() { limit=$(( $1 * 10 )); shift; i=0; while [ $i -lt $limit ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
pyget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pipeline-early.XXXXXX")" && pwd -P)"
DPIDS=""
cleanup() {
  for p in $DPIDS; do kill "$p" 2>/dev/null; done
  [ -n "${KEEP:-}" ] || rm -rf "$T"
}
trap cleanup EXIT
export HQ_ROOT="$T/hq" PC_HQ_ROOT="$T/hq"
mkdir -p "$HQ_ROOT/workspace/sessions"

setup() { # setup <name>
  C="$T/$1"; S="$C/state"; LANE="$C/lane"
  mkdir -p "$S/stories" "$S/envelopes" "$S/handoffs" "$S/driver" "$LANE"
  cat > "$C/prd.json" <<'EOF'
{"name":"early","userStories":[{"id":"S1","title":"t","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["a"]}]}
EOF
  printf '{"id":"S1","title":"t","phases":[{"phase":"backend","worker":"backend-dev"}],"current":0,"state":"in_flight","reroutes":0,"worktree":"%s","started":true,"routed_at":%s}\n' \
    "$C" "$(( $(date +%s) - 30 ))" > "$S/stories/S1.json"
  printf '{"deadline":"2999-01-01T00:00:00Z"}\n' > "$S/envelopes/S1-backend.json"
  : > "$LANE/journal.jsonl"
  cat > "$C/pool" <<EOF
#!/bin/sh
case "\$1" in
  list) printf '[{"worker_id":"backend-dev","status":"running","pid":1,"run_dir":"%s","queue_depth":0}]\n' "$LANE" ;;
  assign) echo "\$*" >> "$C/assigns"; printf '{"action":"enqueue","worker_id":"backend-dev","pid":1,"queued":"%s/q.msg","queue_depth":1}\n' "$LANE" ;;
  *) : ;;
esac
EOF
  chmod +x "$C/pool"
}
phase_exit() { # phase_exit <secs>: the lane journals an early exit for S1/backend now
  printf '{"ts":"%s","event":"phase-exit","story_id":"S1","phase":"backend","worker_id":"backend-dev","reason":"engine error: exit code 1","exit_reason":"engine_exited_early","elapsed_s":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$1" >> "$LANE/journal.jsonl"
}
start_driver() {
  PC_POOL="$C/pool" PIPELINE_DRIVER_POOL="$C/pool" sh "$DRIVER" --prd "$C/prd.json" --state "$S" \
    --interval 0.2 >/dev/null 2>&1 &
  DPID=$!; DPIDS="$DPIDS $DPID"
}
exit_code() { [ -f "$S/driver/exit" ] && cut -d' ' -f1 "$S/driver/exit"; }

# ---- case 1 + 2: handoff missing, one restart, then the owner ------------------
setup one
phase_exit 7
start_driver
wait_for 20 grep -qs "ROUTED\|ACCEPT S1 backend rc=1" "$S/driver/driver.log"
wait_for 20 eval '[ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = in_flight ] && [ -s "$C/assigns" ]'
check "1: tick line names the story, phase and elapsed time" \
  'grep -q "TICK: EARLY_EXIT S1/backend after 7s: engine_exited_early (engine error: exit code 1)" "$S/driver/driver.log"'
check "1: the early exit was accepted as a failed handoff with exit_reason" \
  '[ "$(pyget "$S/handoffs/S1-backend.failed.1.json" "d[\"exit_reason\"]")" = engine_exited_early ] || [ "$(pyget "$S/handoffs/S1-backend.json" "d[\"exit_reason\"]")" = engine_exited_early ]'
check "1: the phase was routed again to the same lane (restart in place) and the driver did not exit" \
  '[ "$(grep -c "assign --worker-id backend-dev" "$C/assigns")" = 1 ] && [ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = in_flight ] && [ ! -f "$S/driver/exit" ]'
sleep 1.1   # the second event must be newer than the re-route
phase_exit 4
wait_for 20 test -f "$S/driver/exit"
check "2: second early exit holds the story: exit 21 naming engine_exited_early" \
  '[ "$(exit_code)" = 21 ] && grep -q "engine_exited_early in 2 of 2 attempt(s)" "$S/driver/exit"'
check "2: S1 is blocked_needs_owner and the decision item names engine_exited_early" \
  '[ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = blocked_needs_owner ] && grep -q engine_exited_early "$S/decisions/S1-blocked-backend.md"'
check "2: no third route" '[ "$(grep -c "assign --worker-id backend-dev" "$C/assigns")" = 1 ]'

# ---- case 3: non-terminal handoff plus phase-exit ------------------------------
setup three
printf '{"schema":"hq-phase-handoff/v1","story_id":"S1","phase":"backend","worker_id":"backend-dev","status":"in_progress","summary":"half"}\n' > "$S/handoffs/S1-backend.json"
phase_exit 12
start_driver
wait_for 20 grep -qs "EARLY_EXIT" "$S/driver/driver.log"
wait_for 20 test -s "$C/assigns"
check "3: a non-terminal handoff with a phase-exit is an early exit, then routed again" \
  'grep -q "TICK: EARLY_EXIT S1/backend after 12s" "$S/driver/driver.log" && [ -s "$C/assigns" ]'
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null

# ---- case 4: non-terminal handoff, engine still running ------------------------
setup four
printf '{"schema":"hq-phase-handoff/v1","story_id":"S1","phase":"backend","worker_id":"backend-dev","status":"in_progress","summary":"half"}\n' > "$S/handoffs/S1-backend.json"
# an old phase-exit from before this phase was routed does not count
printf '{"ts":"2020-01-01T00:00:00.000Z","event":"phase-exit","story_id":"S1","phase":"backend","reason":"old","elapsed_s":1}\n' > "$LANE/journal.jsonl"
start_driver
sleep 2
check "4: no early exit, no accept, no exit: the driver keeps waiting on the deadline" \
  '! grep -q "EARLY_EXIT\|ACCEPTING" "$S/driver/driver.log" && [ ! -f "$S/driver/exit" ] && [ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = in_flight ]'
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null

echo "pipeline-early-exit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
