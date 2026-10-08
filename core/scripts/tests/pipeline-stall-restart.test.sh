#!/bin/bash
# hq-core: public
# shellcheck disable=SC2016,SC2319  # eval strings expand late on purpose; check() takes the test status
# Regression test for per-phase deadlines in `workflow-runner.mjs --loop` and
# the pool's handling of a lane that stalls (US-006).
#
# A FAKE claude binary (HQ_WORKFLOW_CLAUDE_BIN) sleeps when its prompt says
# SLEEP=<n>, so a phase can be driven past a short deadline. Covered:
#   1. first stall: recorded in stalls.jsonl with story, phase, lane, elapsed;
#      the engine call is killed; the lane restarts in place (new pid adopted
#      by the same pool slot); the phase reruns as a fresh call; the two
#      envelopes queued behind it are still in pending/
#   2. second stall of the same phase: no restart, no third run; a decision
#      item names story, phase and lane in <run-dir>/decisions.jsonl and is
#      forwarded to the session's decisions.jsonl; the queued envelopes are
#      still in pending/ and the slot reports idle with queue_depth 2
#   3. another lane keeps processing while the decision is pending
#   4. a phase with no deadline field gets the default and runs normally
#   5. a deadline above the 2^31 ms setTimeout limit does not fire at once

set -uo pipefail
unset HQ_SPAWN_COMPANY HQ_SESSION_ID HQ_PARENT_SESSION_ID HQ_PIPELINE_DECISIONS_FILE HQ_WORKFLOW_LANE \
  CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID HQ_WORKFLOW_PHASE_DEADLINE_SECS
# Isolation: this suite never inherits the caller's session. Its own session id,
# and (below) its own HQ_ROOT with workspace/sessions and run dirs under a temp root,
# keep every pool call, lane and signal inside what this test started.
export HQ_SESSION_ID="test-pipeline-stall-restart-$$"

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RUNNER="$REPO_ROOT/core/scripts/workflow-runner.mjs"
INBOX_SH="$REPO_ROOT/core/scripts/conduct-inbox.sh"
POOL_SH="$REPO_ROOT/core/scripts/conduct-pool.sh"

pass=0
fail=0
check() {
  if [ "$2" -eq 0 ]; then printf 'ok   - %s\n' "$1"; pass=$((pass + 1))
  else printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); fi
}

TMP="$(cd "$(mktemp -d /tmp/pipeline-stall-test.XXXXXX)" && pwd -P)"
PIDS=""
cleanup() {
  local p f
  for f in "$TMP"/lane-*/loop.json; do
    [ -f "$f" ] || continue
    p="$(sed -n 's/^[[:space:]]*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" | head -1)"
    PIDS="$PIDS $p"
  done
  for p in $PIDS; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/rec"
HQROOT="$TMP/hqroot"
mkdir -p "$HQROOT/.claude" "$HQROOT/workspace/sessions"
printf '{}\n' > "$HQROOT/.claude/settings.json"

cat > "$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
rec="${FAKE_REC_DIR:?}"
prompt=""
resume=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --resume) resume="$2"; shift 2 ;;
    --model|--effort|--permission-mode|--output-format|--disallowed-tools|--session-id) shift 2 ;;
    *) shift ;;
  esac
done
tag="$(printf '%s' "$prompt" | sed -n 's/.*TAG=\([A-Za-z0-9_-]*\).*/\1/p')"
printf '%s %s %s\n' "$(date +%s)" "$tag" "${resume:--}" >> "$rec/calls"
case "$prompt" in
  *SLEEP=*) sleep "$(printf '%s' "$prompt" | sed -n 's/.*SLEEP=\([0-9]*\).*/\1/p')" ;;
esac
printf '{"type":"result","subtype":"success","is_error":false,"result":"done %s"}\n' "$tag"
FAKE
chmod +x "$TMP/bin/claude"

export HQ_ROOT="$HQROOT"
export HQ_WORKFLOW_CLAUDE_BIN="$TMP/bin/claude"
export HQ_WORKFLOW_CLAUDE_EXEC_MODEL="fake-model"
export HQ_WORKFLOW_CPU_CHECK=0
export HQ_WORKFLOW_LOOP_POLL_MS=50
export FAKE_REC_DIR="$TMP/rec"

SID="stall-test"
pool() { bash "$POOL_SH" --session-id "$SID" "$@"; }
send() { bash "$INBOX_SH" send --run-dir "$1" --text "$2" >/dev/null; }
wait_for() { # wait_for <secs> <command...>
  local limit=$(( $1 * 10 )); shift
  local i=0
  while [ $i -lt $limit ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
count() { find "$1" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' '; }
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
runs_of() { [ -f "$TMP/rec/calls" ] && awk -v t="$1" '$2 == t' "$TMP/rec/calls" | wc -l | tr -d ' ' || echo 0; }
loop_pid() { sed -n 's/^[[:space:]]*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1/loop.json" 2>/dev/null | head -1; }
alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
jfield() { node -e 'const j=JSON.parse(process.argv[1]); const v=j[process.argv[2]]; process.stdout.write(v===undefined||v===null?"":String(v))' "$1" "$2"; }
slot_json() { pool list | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s).find(x=>x.worker_id===process.argv[1]);process.stdout.write(JSON.stringify(r||{}))})' "$1"; }

start_lane() { # start_lane <dir> -> sets STARTED_PID
  node "$RUNNER" --loop --quiet --run-dir "$1" >> "$1.out" 2>> "$1.err" &
  STARTED_PID=$!
  PIDS="$PIDS $STARTED_PID"
  wait_for 10 test -f "$1/loop.json"
}

LANE_A="$TMP/lane-a"
LANE_B="$TMP/lane-b"
mkdir -p "$LANE_A" "$LANE_B"

# ---- lanes in the pool -------------------------------------------------------
start_lane "$LANE_A"; PID_A="$STARTED_PID"
start_lane "$LANE_B"; PID_B="$STARTED_PID"
pool assign --worker-id lane-a >/dev/null
pool record --worker-id lane-a --subagent-id loop-a --status waiting --pid "$PID_A" --run-dir "$LANE_A" >/dev/null
pool assign --worker-id lane-b >/dev/null
pool record --worker-id lane-b --subagent-id loop-b --status waiting --pid "$PID_B" --run-dir "$LANE_B" >/dev/null

# ---- 4. default deadline: a phase with no deadline field runs normally ---------
send "$LANE_B" '{"kind":"phase","engine":"claude","worker_id":"lane-b","story_id":"US-9","phase":"warm","prompt":"TAG=warm"}'
wait_for 15 eval '[ "$(count "$LANE_B/inbox/results")" -ge 1 ]'
rb="$(find "$LANE_B/inbox/results" -name '*.json' | head -1)"
check "phase without a deadline field completes under the default deadline" \
  "$([ "$(jfield "$(cat "$rb")" status)" = ok ]; echo $?)"

# ---- 1. first stall -> restart in place, rerun fresh, queue intact ------------
send "$LANE_A" '{"kind":"phase","engine":"claude","worker_id":"lane-a","story_id":"US-1","phase":"build","deadline_seconds":3,"id":"stuck","prompt":"TAG=stuck SLEEP=30"}'
wait_for 10 eval '[ "$(runs_of stuck)" -ge 1 ]'
send "$LANE_A" '{"kind":"phase","engine":"claude","worker_id":"lane-a","story_id":"US-2","phase":"build","id":"q1","prompt":"TAG=q1"}'
send "$LANE_A" '{"kind":"phase","engine":"claude","worker_id":"lane-a","story_id":"US-2","phase":"review","id":"q2","prompt":"TAG=q2"}'
check "two envelopes queued behind the running phase" "$([ "$(count "$LANE_A/inbox/pending")" = 2 ]; echo $?)"

wait_for 15 eval '[ "$(lines "$LANE_A/stalls.jsonl")" -ge 1 ]'
s1="$(sed -n 1p "$LANE_A/stalls.jsonl")"
check "first stall recorded with story, phase, lane and elapsed time" \
  "$([ "$(jfield "$s1" story_id)" = US-1 ] && [ "$(jfield "$s1" phase)" = build ] \
     && [ "$(jfield "$s1" lane)" = lane-a ] && [ -n "$(jfield "$s1" elapsed_s)" ] \
     && [ "$(jfield "$s1" action)" = restart ]; echo $?)"
# The first lane process is this shell's child: reap it so kill -0 stops
# seeing a zombie (a detached lane is reaped by its own parent).
exited_or_zombie() { case "$(ps -o stat= -p "$1" 2>/dev/null)" in ''|Z*) return 0 ;; *) return 1 ;; esac; }
if wait_for 10 exited_or_zombie "$PID_A"; then wait "$PID_A" 2>/dev/null; fi
wait_for 10 eval '[ "$(runs_of stuck)" -ge 2 ]'
check "no decision item after the first stall" "$([ ! -s "$LANE_A/decisions.jsonl" ]; echo $?)"
NEW_A="$(loop_pid "$LANE_A")"
check "lane restarted in place: new pid in the same run dir, old pid gone" \
  "$([ -n "$NEW_A" ] && [ "$NEW_A" != "$PID_A" ] && alive "$NEW_A" && ! alive "$PID_A"; echo $?)"
PIDS="$PIDS $NEW_A"
check "stalled phase reran (2 runs so far)" "$([ "$(runs_of stuck)" = 2 ]; echo $?)"
check "rerun is a fresh call, not a resume" \
  "$([ "$(awk '$2 == "stuck" {print $3}' "$TMP/rec/calls" | sed -n 2p)" = - ]; echo $?)"
check "after the restart both queued envelopes are still in pending/" \
  "$([ "$(count "$LANE_A/inbox/pending")" = 2 ]; echo $?)"
slot="$(slot_json lane-a)"
check "pool keeps the same slot and adopts the new pid" \
  "$([ "$(jfield "$slot" pid)" = "$NEW_A" ] && [ "$(jfield "$slot" status)" = running ]; echo $?)"

# ---- 2. second stall -> decision item, no restart, queue intact ---------------
wait_for 15 eval '[ "$(lines "$LANE_A/decisions.jsonl")" -ge 1 ]'
wait_for 5 eval '! alive "$NEW_A"'
d1="$(sed -n 1p "$LANE_A/decisions.jsonl")"
check "one decision item naming story, phase and lane" \
  "$([ "$(lines "$LANE_A/decisions.jsonl")" = 1 ] && [ "$(jfield "$d1" story_id)" = US-1 ] \
     && [ "$(jfield "$d1" phase)" = build ] && [ "$(jfield "$d1" lane)" = lane-a ] \
     && [ "$(jfield "$d1" status)" = pending ]; echo $?)"
check "two stalls recorded, the second asking for a decision" \
  "$([ "$(lines "$LANE_A/stalls.jsonl")" = 2 ] && [ "$(jfield "$(sed -n 2p "$LANE_A/stalls.jsonl")" action)" = decision ]; echo $?)"
check "the lane process stopped and was not restarted" \
  "$(! alive "$NEW_A" && [ "$(loop_pid "$LANE_A")" = "$NEW_A" ]; echo $?)"
check "stalled envelope parked in stalled/" "$([ "$(count "$LANE_A/inbox/stalled")" = 1 ]; echo $?)"
check "both queued envelopes still in pending/ after the decision" \
  "$([ "$(count "$LANE_A/inbox/pending")" = 2 ]; echo $?)"

# ---- 3. other lane keeps moving while the decision is pending -----------------
send "$LANE_B" '{"kind":"phase","engine":"claude","worker_id":"lane-b","story_id":"US-3","phase":"build","deadline_seconds":20,"prompt":"TAG=other"}'
wait_for 15 eval '[ "$(count "$LANE_B/inbox/results")" -ge 2 ]'
check "another lane processes a phase while the decision is pending" "$([ "$(runs_of other)" = 1 ]; echo $?)"
check "the other lane is still alive" "$(alive "$PID_B"; echo $?)"

# ---- 5. a deadline longer than the setTimeout limit must not stall at once ----
send "$LANE_B" '{"kind":"phase","engine":"claude","worker_id":"lane-b","story_id":"US-4","phase":"build","deadline_seconds":3000000,"prompt":"TAG=longdl SLEEP=1"}'
wait_for 15 eval '[ "$(count "$LANE_B/inbox/results")" -ge 3 ]'
check "a deadline past the 2^31 ms timer limit does not stall the phase" \
  "$([ ! -s "$LANE_B/stalls.jsonl" ] && [ "$(runs_of longdl)" = 1 ] && alive "$PID_B"; echo $?)"

sleep 3
check "no third run of the stalled phase" "$([ "$(runs_of stuck)" = 2 ]; echo $?)"
check "queued envelopes never ran" "$([ "$(runs_of q1)" = 0 ] && [ "$(runs_of q2)" = 0 ]; echo $?)"

dec="$(pool decisions)"
check "pool decisions forwards the item to the session decisions file" \
  "$([ -f "$HQROOT/workspace/sessions/$SID/decisions.jsonl" ] && [ "$(printf '%s\n' "$dec" | grep -c '"story_id":"US-1"')" = 1 ]; echo $?)"
pool list >/dev/null
check "forwarding is idempotent across calls" \
  "$([ "$(lines "$HQROOT/workspace/sessions/$SID/decisions.jsonl")" = 1 ]; echo $?)"
slot="$(slot_json lane-a)"
check "stalled slot shows idle with its queue kept (queue_depth 2)" \
  "$([ "$(jfield "$slot" status)" = idle ] && [ "$(jfield "$slot" queue_depth)" = 2 ]; echo $?)"
slot="$(slot_json lane-b)"
check "other slot is unaffected (waiting, same pid)" \
  "$([ "$(jfield "$slot" status)" = waiting ] && [ "$(jfield "$slot" pid)" = "$PID_B" ]; echo $?)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
