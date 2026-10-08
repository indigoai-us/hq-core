#!/usr/bin/env bash
# End-to-end test for /run-project --pipeline with a stub engine (no model calls).
#
# Real pieces: workflow-runner.mjs --loop lanes, conduct-pool.sh, the confirmed
# worker table (pipeline-worker-table.sh), pipeline-conductor.sh,
# pipeline-envelope.sh, and pipeline-driver.sh launched through hq-detach.sh.
# Stub: the claude binary (HQ_WORKFLOW_CLAUDE_BIN). It reads the story id, phase
# and worker from the prompt the lane built, records the call, and replies with
# a section 8 handoff that meets every acceptance criterion.
#
# Case A: two stories, two phases each (backend-dev -> qa-tester). Asserts that
#   a conductor-built envelope runs in a lane, its handoff validates and lands
#   at result_path, the driver accepts it and routes the next phase to the next
#   worker's lane, both stories verify, the driver exits 0 with its exit file,
#   and stop envelopes leave no waiting or running slot in the pool.
# Case B: the driver is killed (SIGKILL) mid-run and restarted; the run still
#   completes and no phase runs twice. A second driver against a live one is
#   refused with exit 24.
# Case C: one story at a time; S1's phase returns blocked. S1 is held, never
#   routed again, a decision item is written, the independent S3 still
#   completes, and the driver exits 21 only when nothing else can move.
# Case D: after `resolve --as accepted-partial` on C's state, the dependent S2
#   routes and completes, the driver exits 0, and the summary marks S1 as a
#   partial draft with passes not set.
# Case E: S1 blocks again; after `park`, S2 is held as parked_dependency, S3
#   completes, and the driver exits 0 with the parked story listed.
# Case F: stall. A phase is in flight past --stall-window, no handoff, and the
#   pool lists every started lane waiting with an empty queue: one stall event
#   in events.jsonl and exit 28; a restarted driver does not fire it again, and
#   accepting a phase clears it.
# Case G: a phase that returned failed twice stops the driver with exit 21 and
#   a reason that counts both attempts and names the status.
# Case H: a dead loop lane at route time (pool answers resume): exit 26 naming
#   the lane, the story stays queued; after a fresh lane starts, the restarted
#   driver completes the run.
# Case I: qa listed first fails twice: exit 21 with the story held for the owner
#   and a decision item; after worker_preference is fixed and resolve --as
#   retry, the restarted driver routes the new first phase and completes.
# Case K: three stories; one is unclassified by keywords and the overlay
#   classifies it, one is skipped; the run completes and FINAL lists the skip.
# Case L: a sequence worker with no row in the confirmed table: exit 27.
# Case M: a phase whose engine exits early is routed once more to the same lane,
#   then held for the owner; exit 21 and the decision item name engine_exited_early.
# Case N: `pipeline-conductor.sh stop` while a phase is in flight: exit 29, the
#   story is interrupted; the restarted driver routes it first with
#   resumed_after_interrupt and the run completes.
# bash 3.2 portable.
set -u
unset HQ_SPAWN_COMPANY HQ_SESSION_ID HQ_PARENT_SESSION_ID HQ_PIPELINE_DECISIONS_FILE HQ_WORKFLOW_LANE \
  CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID HQ_WORKFLOW_PHASE_DEADLINE_SECS \
  HQ_CONDUCT_RUN_DIR HQ_CONDUCT_ENGINE PC_WORKERS_ROOT PC_POOL PC_ENVELOPE PC_NOW PC_MAX_STORIES
# Isolation: this suite never inherits the caller's session. Its own session id,
# and (below) its own HQ_ROOT with workspace/sessions and run dirs under a temp root,
# keep every pool call, lane and signal inside what this test started.
export HQ_SESSION_ID="test-pipeline-e2e-$$"

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
RUNNER="$SCRIPTS/workflow-runner.mjs"
POOL_SH="$SCRIPTS/conduct-pool.sh"
PC="$SCRIPTS/pipeline-conductor.sh"
PE="$SCRIPTS/pipeline-envelope.sh"
TABLE="$SCRIPTS/pipeline-worker-table.sh"
DRIVER="${PIPELINE_E2E_DRIVER:-$SCRIPTS/pipeline-driver.sh}"  # the isolation guard runs a reverted driver here
DETACH="$SCRIPTS/hq-detach.sh"

pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pipeline-e2e.XXXXXX")" && pwd -P)"
PIDS=""
cleanup() {
  for f in "$T"/case-*/lanes/*/loop.json "$T"/case-*/lanes2/*/loop.json; do
    [ -f "$f" ] || continue
    PIDS="$PIDS $(sed -n 's/^[[:space:]]*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" | head -1)"
  done
  for f in "$T"/case-*/state/driver/driver.pid; do [ -f "$f" ] && PIDS="$PIDS $(cat "$f")"; done
  for p in $PIDS; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  [ -n "${KEEP:-}" ] || rm -rf "$T"
}
trap cleanup EXIT

wait_for() { # wait_for <secs> <command...>
  limit=$(( $1 * 10 )); shift
  i=0
  while [ $i -lt $limit ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
pyget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

# ---- synthetic HQ root with two workers -------------------------------------
HQ="$T/hq"
mkdir -p "$HQ/.claude" "$HQ/workspace/sessions" "$HQ/core/workers" "$T/bin"
printf '{}\n' > "$HQ/.claude/settings.json"
for w in backend-dev qa-tester; do
  mkdir -p "$HQ/personal/workers/public/dev-team/$w"
  printf 'worker:\n  id: %s\n  name: "%s"\n  description: "test worker"\nverification:\n  approval_required: false\n' \
    "$w" "$w" > "$HQ/personal/workers/public/dev-team/$w/worker.yaml"
done

# ---- stub claude ------------------------------------------------------------
cat > "$T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --model|--effort|--permission-mode|--output-format|--disallowed-tools|--session-id|--resume) shift 2 ;;
    *) shift ;;
  esac
done
sid="$(printf '%s\n' "$prompt" | sed -n 's/^- Story id: //p' | head -1)"
phase="$(printf '%s\n' "$prompt" | sed -n 's/^- Phase: //p' | head -1)"
worker="$(printf '%s\n' "$prompt" | sed -n 's/^You are the `\([^`]*\)` worker.*/\1/p' | head -1)"
printf '%s %s %s\n' "$sid" "$phase" "$worker" >> "$FAKE_REC"
printf '%s\n----\n' "$prompt" >> "$FAKE_REC.prompts"
# an engine that quits before writing any reply
if [ -f "$FAKE_EARLY" ] && grep -qx "$sid $phase" "$FAKE_EARLY"; then echo "stub: engine quit early" >&2; exit 1; fi
[ -f "$FAKE_SLEEP" ] && sleep "$(cat "$FAKE_SLEEP")"
python3 - "$sid" "$phase" "$worker" "$prompt" "$FAKE_BLOCK" "$FAKE_FAIL" <<'PY'
import json, os, re, sys
sid, phase, worker, prompt, block, failf = sys.argv[1:7]
blocked = os.path.exists(block) and sid in open(block).read().split()
failing = os.path.exists(failf) and ("%s %s" % (sid, phase)) in open(failf).read().splitlines()
acs = re.findall(r"^(\d+)\. (.*)$", prompt.split("## Acceptance criteria", 1)[-1].split("##", 1)[0], re.M)
h = {"schema": "hq-phase-handoff/v1", "story_id": sid, "phase": phase, "worker_id": worker,
     "status": "passed", "summary": "stub did %s" % phase, "files_changed": [], "commits": [],
     "back_pressure": {"tests": "pass", "lint": "pass", "typecheck": "pass", "build": "skip"},
     "context_for_next": "", "ac_evidence": [{"index": int(i), "met": True, "evidence": "stub check %s" % i,
                                              "criterion": c} for i, c in acs]}
if blocked:
    h.update({"status": "blocked", "summary": "stub blocker: two criteria need a person to run trials",
              "notes": "a rerun cannot change this", "ac_evidence": h["ac_evidence"][:1]})
if failing:
    n = len([l for l in open(os.environ["FAKE_REC"]).read().splitlines() if l.startswith("%s %s " % (sid, phase))])
    h.update({"status": "failed", "summary": "stub failure %d: %s has nothing to test yet" % (n, phase),
              "back_pressure": dict(h["back_pressure"], tests="fail")})
print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": json.dumps(h)}))
PY
FAKE
chmod +x "$T/bin/claude"

export HQ_ROOT="$HQ" PC_HQ_ROOT="$HQ"
export HQ_WORKFLOW_CLAUDE_BIN="$T/bin/claude" HQ_WORKFLOW_CPU_CHECK=0 HQ_WORKFLOW_LOOP_POLL_MS=50
export PC_GATE_EVERY=5 PC_MAX_STORIES=2

# ---- one case: fixture, lanes, driver -----------------------------------------
setup_case() { # setup_case <name>
  C="$T/case-$1"; S="$C/state"; SID="e2e-$1"
  mkdir -p "$C/lanes" "$S"
  export FAKE_REC="$C/calls" FAKE_SLEEP="$C/sleep" FAKE_BLOCK="$C/block" FAKE_FAIL="$C/fail" FAKE_EARLY="$C/early"
  : > "$FAKE_REC"
  WT="$HQ/workspace/worktrees/e2e/wt-$1"; mkdir -p "$WT"; git -C "$WT" init -q
  cat > "$C/prd.json" <<'EOF'
{"name":"e2e","userStories":[
 {"id":"S1","title":"First story","description":"first","priority":1,"passes":false,"dependsOn":[],
  "worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["S1 AC zero","S1 AC one"]},
 {"id":"S2","title":"Second story","description":"second","priority":2,"passes":false,"dependsOn":["S1"],
  "worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["S2 AC zero"]}
]}
EOF
  if [ "${WITH_S3:-0}" = 1 ]; then
    python3 - "$C/prd.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["userStories"].append({"id": "S3", "title": "Independent story", "description": "third", "priority": 3,
  "passes": False, "dependsOn": [], "worker_preference": ["backend-dev", "qa-tester"],
  "acceptanceCriteria": ["S3 AC zero"]})
json.dump(d, open(p, "w"))
PY
  fi
  printf 'backend-dev\tclaude\tfake-model\tlow\nqa-tester\tclaude\tfake-model\tlow\n' > "$C/table.tsv"
  bash "$TABLE" --confirmed "$C/table.tsv" "$C/prd.json" > "$C/lanes.env"
  # the conductor reaches the real pool through this session-pinned wrapper
  printf '#!/usr/bin/env bash\nexec bash "%s" --session-id "%s" "$@"\n' "$POOL_SH" "$SID" > "$C/pool"
  chmod +x "$C/pool"
  export PC_POOL="$C/pool"
  for w in backend-dev qa-tester; do start_lane "$w" "$C/lanes/$w"; done
}

start_lane() { # start_lane <worker> <run dir>: a real loop lane, recorded waiting in this case's pool
  lane="$2"; mkdir -p "$lane"
  exports="$(sed -n "/^# lane $1 (/,/^# lane /p" "$C/lanes.env" | grep '^export ')"
  ( eval "$exports"; exec node "$RUNNER" --loop --quiet --run-dir "$lane" >> "$lane.out" 2>> "$lane.err" ) &
  pid=$!; PIDS="$PIDS $pid"
  wait_for 10 test -f "$lane/loop.json"
  "$C/pool" assign --worker-id "$1" >/dev/null
  "$C/pool" record --worker-id "$1" --subagent-id "loop-$1" --status waiting --pid "$pid" --run-dir "$lane" >/dev/null
}

start_driver() {
  bash "$DETACH" --logfile "$S/driver/detach.log" -- \
    sh "$DRIVER" --prd "$C/prd.json" --state "$S" --worktree "$WT" --interval 0.2
}
driver_exit_code() { [ -f "$S/driver/exit" ] && cut -d' ' -f1 "$S/driver/exit"; }
lane_results() { ls "$C/lanes/$1/inbox/results" 2>/dev/null | grep -c '\.json$'; }
calls_for() { grep -c "^$1 $2 " "$C/calls" 2>/dev/null; }
slot_statuses() { "$C/pool" list | python3 -c 'import json,sys; print(" ".join(sorted(r["status"] for r in json.load(sys.stdin))))'; }

stop_lanes() {
  printf '{"kind":"stop"}\n' > "$C/stop.json"
  for w in backend-dev qa-tester; do "$C/pool" assign --worker-id "$w" --envelope "$C/stop.json" >/dev/null; done
  for w in backend-dev qa-tester; do
    p="$(sed -n 's/^[[:space:]]*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$C/lanes/$w/loop.json" | head -1)"
    wait_for 15 eval "! kill -0 $p 2>/dev/null"
  done
}

# ============================== case A ========================================
setup_case a
mkdir -p "$S/driver"
start_driver
wait_for 60 test -f "$S/driver/exit"
check "A: driver exits with its all-done code 0" '[ "$(driver_exit_code)" = 0 ]'
check "A: driver log is append-only with START and EXIT" 'grep -q " START " "$S/driver/driver.log" && grep -q " EXIT 0 " "$S/driver/driver.log"'
check "A: driver removed its pid file and lock on exit" '[ ! -e "$S/driver/driver.pid" ] && [ ! -d "$S/driver/lock" ]'

E1="$S/envelopes/S1-backend.json"
check "A: conductor built a section 8 envelope with a result_path" \
  '"$PE" validate --kind envelope "$E1" >/dev/null 2>&1 && [ "$(pyget "$E1" "d[\"result_path\"]")" = "$S/handoffs/S1-backend.json" ]'
check "A: the backend envelope ran in the backend-dev lane" '[ "$(lane_results backend-dev)" = 2 ] && grep -q "S1-backend" "$C"/lanes/backend-dev/inbox/results/*.json'
check "A: the qa phase was routed to the qa-tester lane" '[ "$(lane_results qa-tester)" = 2 ] && grep -q "S1-qa" "$C"/lanes/qa-tester/inbox/results/*.json'
check "A: the stub engine ran each phase as its own worker" \
  'grep -qx "S1 backend backend-dev" "$C/calls" && grep -qx "S1 qa qa-tester" "$C/calls" && grep -qx "S2 backend backend-dev" "$C/calls" && grep -qx "S2 qa qa-tester" "$C/calls"'
ok_handoffs=1
for h in S1-backend S1-qa S2-backend S2-qa; do
  "$PE" validate --kind handoff "$S/handoffs/$h.json" >/dev/null 2>&1 || ok_handoffs=0
done
check "A: every handoff at result_path validates" '[ $ok_handoffs = 1 ]'
check "A: driver accepted each handoff and routed the next phase" \
  'grep -q "ACCEPT S1 backend rc=0: NEXT S1 qa" "$S/driver/driver.log" && grep -q "ROUTED S1 qa qa-tester" "$S/driver/driver.log" && grep -q "ACCEPT S2 qa rc=0: RECHECK S2" "$S/driver/driver.log"'
check "A: both stories verified" '[ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = verified ] && [ "$(pyget "$S/stories/S2.json" "d[\"state\"]")" = verified ]'
check "A: report has the final line" 'grep -q "^FINAL: verified 2, failed 0" "$S/report.md"'
check "A: each phase ran exactly once" '[ "$(wc -l < "$C/calls" | tr -d " ")" = 4 ]'
stop_lanes
check "A: stop envelopes leave no waiting or running slot" '! slot_statuses | grep -qE "waiting|running|claimed"'

# ============================== case B ========================================
setup_case b
mkdir -p "$S/driver"
printf '1.5\n' > "$C/sleep"
start_driver
wait_for 15 test -f "$S/driver/driver.pid"
DPID="$(cat "$S/driver/driver.pid")"
# a second copy against the same state dir is refused
sh "$DRIVER" --prd "$C/prd.json" --state "$S" --worktree "$WT" --interval 0.2 2>/dev/null; rc2=$?
check "B: a second driver against a live one exits 24" '[ $rc2 = 24 ]'
check "B: the refused copy left the live driver's lock alone" '[ "$(cat "$S/driver/lock/pid")" = "$DPID" ]'
# kill it while S1's backend phase is in flight (the stub sleeps 1.5s per phase)
wait_for 30 grep -q "ROUTED S1 backend" "$S/driver/driver.log"
kill -9 "$DPID" 2>/dev/null
wait_for 5 eval '! kill -0 "$DPID" 2>/dev/null'
check "B: driver was killed mid-run, before the run finished" \
  '! kill -0 "$DPID" 2>/dev/null && [ ! -f "$S/driver/exit" ] && [ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" != verified ] && [ ! -f "$S/stories/S2.json" ]'
sleep 1
start_driver
wait_for 90 test -f "$S/driver/exit"
check "B: restarted driver took over the stale lock" 'grep -q "STALE_LOCK pid=$DPID" "$S/driver/driver.log"'
check "B: restarted driver exits with its all-done code 0" '[ "$(driver_exit_code)" = 0 ]'
check "B: both stories verified after the restart" '[ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = verified ] && [ "$(pyget "$S/stories/S2.json" "d[\"state\"]")" = verified ]'
once=1
for k in "S1 backend" "S1 qa" "S2 backend" "S2 qa"; do
  [ "$(calls_for ${k% *} ${k#* })" = 1 ] || once=0
done
check "B: no phase ran twice across the restart" '[ $once = 1 ] && [ "$(wc -l < "$C/calls" | tr -d " ")" = 4 ]'
check "B: the restarted driver accepted the handoff that landed while no driver ran" \
  '[ "$(grep -c "ACCEPT S1 backend rc=0: NEXT S1 qa" "$S/driver/driver.log")" = 1 ] && [ "$(grep -c "ACCEPTING S1 backend" "$S/driver/driver.log")" = 1 ]'
"$PC" accept --state "$S" --story S1 --handoff "$S/handoffs/S1-backend.json" > "$C/reaccept.out" 2>&1; rra=$?
check "B: accepting the same handoff again changes nothing" \
  '[ $rra != 0 ] && [ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = verified ] && [ "$(pyget "$S/stories/S1.json" "d[\"current\"]")" = 1 ]'
check "B: no conductor call failed during the run" '! grep -qE "ACCEPT .* rc=[^0]|EXIT 2[0-9]" "$S/driver/driver.log"'
stop_lanes
check "B: stop envelopes leave no waiting or running slot" '! slot_statuses | grep -qE "waiting|running|claimed"'

# ============================== case C ========================================
WITH_S3=1 setup_case c
mkdir -p "$S/driver"
printf 'S1\n' > "$C/block"
cp "$C/prd.json" "$C/prd.before"
PC_MAX_STORIES=1 start_driver
wait_for 60 test -f "$S/driver/exit"
check "C: driver exits 21 (decision needed) only after the rest moved" \
  '[ "$(driver_exit_code)" = 21 ] && grep -q "decision needed, nothing else can move: blocked by its worker: S1/backend" "$S/driver/exit"'
check "C: the blocked story is held, not re-queued" '[ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = blocked_needs_owner ]'
check "C: the blocked phase ran once and was not re-routed" '[ "$(calls_for S1 backend)" = 1 ] && [ "$(grep -c "ROUTED S1 backend" "$S/driver/driver.log")" = 1 ]'
check "C: one decision item with the worker's own blocker text" \
  '[ "$(ls "$S/decisions" | wc -l | tr -d " ")" = 1 ] && grep -q "two criteria need a person to run trials" "$S/decisions/S1-blocked-backend.md" && grep -q "lane: backend-dev" "$S/decisions/S1-blocked-backend.md"'
check "C: the independent story still completed" '[ "$(pyget "$S/stories/S3.json" "d[\"state\"]")" = verified ]'
check "C: the dependent story did not start" '[ ! -f "$S/stories/S2.json" ]'

# ============================== case D ========================================
"$PC" resolve --state "$S" --story S1 --as accepted-partial --note "owner accepts the draft" > "$C/resolve.out" 2>&1; rres=$?
check "D: resolve --as accepted-partial succeeds on the driver's state" '[ $rres = 0 ] && grep -q "RESOLVED S1 accepted-partial unmet:1" "$C/resolve.out"'
PC_MAX_STORIES=1 start_driver
wait_for 60 eval '[ -f "$S/driver/exit" ] && [ "$(driver_exit_code)" != 21 ]'
check "D: driver exits 0 (all done)" '[ "$(driver_exit_code)" = 0 ]'
check "D: the dependent story routed and verified" '[ "$(pyget "$S/stories/S2.json" "d[\"state\"]")" = verified ] && [ "$(calls_for S2 qa)" = 1 ]'
check "D: S1 was not routed again" '[ "$(calls_for S1 backend)" = 1 ] && [ "$(calls_for S1 qa)" = 0 ]'
check "D: summary marks S1 partial with passes not set" \
  'grep -q "^FINAL: verified 2, failed 0, partial 1, .*partial drafts, passes not set: S1" "$S/report.md" && grep -q "^- S1 accepted by the owner as a partial draft, not verified; passes is not set" "$S/report.md"'
check "D: prd passes flags untouched" 'cmp -s "$C/prd.json" "$C/prd.before"'
stop_lanes

# ============================== case E ========================================
WITH_S3=1 setup_case e
mkdir -p "$S/driver"
printf 'S1\n' > "$C/block"
PC_MAX_STORIES=1 start_driver
wait_for 60 test -f "$S/driver/exit"
check "E: driver stops 21 on the blocked story" '[ "$(driver_exit_code)" = 21 ]'
"$PC" park --state "$S" --story S1 --note "vendor answer pending" > "$C/park.out" 2>&1; rpk=$?
check "E: park succeeds and holds the dependent" '[ $rpk = 0 ] && [ "$(pyget "$S/stories/S2.json" "d[\"state\"]")" = parked_dependency ]'
PC_MAX_STORIES=1 start_driver
wait_for 60 eval '[ -f "$S/driver/exit" ] && [ "$(driver_exit_code)" != 21 ]'
check "E: driver exits 0 (all done) with the parked story listed" \
  '[ "$(driver_exit_code)" = 0 ] && grep -q "parked S1 (vendor answer pending; holds S2)" "$S/report.md"'
check "E: the rest completed; the dependent never ran" '[ "$(pyget "$S/stories/S3.json" "d[\"state\"]")" = verified ] && [ "$(calls_for S2 backend)" = 0 ]'
stop_lanes

# ============================== case F ========================================
C="$T/case-f"; S="$C/state"; mkdir -p "$S/stories" "$S/envelopes" "$S/handoffs" "$S/driver"
cat > "$C/prd.json" <<'EOF'
{"name":"e2e","userStories":[{"id":"S1","title":"t","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["a"]}]}
EOF
printf '{"id":"S1","title":"t","phases":[{"phase":"backend","worker":"backend-dev"}],"current":0,"state":"in_flight","reroutes":0,"worktree":"%s","started":true,"routed_at":%s}\n' \
  "$C" "$(( $(date +%s) - 120 ))" > "$S/stories/S1.json"
printf '{"deadline":"2999-01-01T00:00:00Z"}\n' > "$S/envelopes/S1-backend.json"
printf '#!/bin/sh\ncat "%s/pool.json"\n' "$C" > "$C/fpool"; chmod +x "$C/fpool"
printf '[{"worker_id":"backend-dev","status":"running","pid":1,"queue_depth":0}]\n' > "$C/pool.json"
PIPELINE_DRIVER_POOL="$C/fpool" bash "$DETACH" --logfile "$S/driver/detach.log" -- \
  sh "$DRIVER" --prd "$C/prd.json" --state "$S" --interval 0.2 --stall-window 60
sleep 2
check "F: a lane still running is not a stall" '[ ! -f "$S/driver/exit" ]'
printf '[{"worker_id":"backend-dev","status":"waiting","pid":1,"queue_depth":0},{"worker_id":"qa-tester","status":"recycled","pid":null,"queue_depth":0}]\n' > "$C/pool.json"
wait_for 15 test -f "$S/driver/exit"
check "F: every started lane waiting with an empty queue -> stall event, exit 28 and one log line" \
  '[ "$(driver_exit_code)" = 28 ] && [ "$(grep -c " STALL since .* stories=S1 lanes=backend-dev" "$S/driver/driver.log")" = 1 ]'
check "F: events.jsonl carries one stall event naming the story, the lane and since" \
  '[ "$(grep -c "\"event\": \"stall\"" "$S/events.jsonl")" = 1 ] && grep -q "\"stories\": \[\"S1\"\], \"lanes\": \[\"backend-dev\"\], \"since\": \"" "$S/events.jsonl"'
# Fire once: a restarted driver against the same stall does not fire again.
rm -f "$S/driver/exit"
PIPELINE_DRIVER_POOL="$C/fpool" bash "$DETACH" --logfile "$S/driver/detach.log" -- \
  sh "$DRIVER" --prd "$C/prd.json" --state "$S" --interval 0.2 --stall-window 60
sleep 2
check "F: the same stall does not fire again after a restart" \
  '[ ! -f "$S/driver/exit" ] && [ "$(grep -c "\"event\": \"stall\"" "$S/events.jsonl")" = 1 ]'
# SIGKILL, not TERM: a TERM stop marks the in-flight S1 interrupted (case N), and
# this check needs S1 still in flight when its handoff lands
fdpid="$(cat "$S/driver/driver.pid" 2>/dev/null)"
kill -9 "$fdpid" 2>/dev/null
wait_for 10 eval '! kill -0 "$fdpid" 2>/dev/null'
# Clear on accept: a handoff lands, the phase is accepted and stall.json goes.
printf '{"schema":"hq-phase-handoff/v1","story_id":"S1","phase":"backend","worker_id":"backend-dev","status":"failed","summary":"s"}\n' > "$S/handoffs/S1-backend.json"
rm -f "$S/driver/exit"
PIPELINE_DRIVER_POOL="$C/fpool" sh "$DRIVER" --prd "$C/prd.json" --state "$S" --interval 0.2 --stall-window 60 >/dev/null 2>&1 &
fpid=$!
wait_for 20 grep -q "ACCEPT S1 backend rc=" "$S/driver/driver.log"
check "F: accepting a phase clears the stall" '[ ! -f "$S/driver/stall.json" ] && grep -q "ACCEPT S1 backend rc=1" "$S/driver/driver.log"'
kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null

# ============================== case G ========================================
C="$T/case-g"; S="$C/state"; mkdir -p "$S/stories" "$S/envelopes" "$S/handoffs" "$S/driver"
cp "$T/case-f/prd.json" "$C/prd.json"
printf '{"id":"S1","title":"t","phases":[{"phase":"backend","worker":"backend-dev"}],"current":0,"state":"queued","reroutes":0,"worktree":"%s","started":true}\n' \
  "$C" > "$S/stories/S1.json"
for f in S1-backend.failed.1.json S1-backend.json; do
  printf '{"schema":"hq-phase-handoff/v1","story_id":"S1","phase":"backend","worker_id":"backend-dev","status":"failed","summary":"s"}\n' > "$S/handoffs/$f"
done
PIPELINE_DRIVER_POOL="$C/none" sh "$DRIVER" --prd "$C/prd.json" --state "$S" --interval 0.2 >/dev/null 2>&1
check "G: two failed attempts stop with 21, counting both and naming the status" \
  '[ "$(driver_exit_code)" = 21 ] && grep -q "returned handoff status failed in 2 of 2 attempt(s)" "$S/driver/exit"'

# ============================== case H ========================================
# Lane down at route time: the backend-dev loop lane is stopped before the driver
# starts, so the pool answers resume, not enqueue. The driver exits 26 naming the
# lane, S1 stays queued and its claim is released. After a fresh backend-dev lane
# is started, the restarted driver routes S1 normally and completes the run.
setup_case h
mkdir -p "$S/driver"
printf '{"kind":"stop"}\n' > "$C/stop.json"
"$C/pool" assign --worker-id backend-dev --envelope "$C/stop.json" >/dev/null
hp="$(sed -n 's/^[[:space:]]*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$C/lanes/backend-dev/loop.json" | head -1)"
wait_for 15 eval "! kill -0 $hp 2>/dev/null"
start_driver
wait_for 30 test -f "$S/driver/exit"
check "H: a dead lane at route time exits 26 and names the lane" \
  '[ "$(driver_exit_code)" = 26 ] && grep -q "lane down: backend-dev" "$S/driver/exit" && [ "$(grep -c " LANE_DOWN lane backend-dev is down" "$S/driver/driver.log")" = 1 ]'
check "H: the story is still queued, nothing ran, no slot left claimed" \
  '[ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = queued ] && [ ! -s "$C/calls" ] && ! slot_statuses | grep -q claimed'
start_lane backend-dev "$C/lanes2/backend-dev"
start_driver
wait_for 60 eval '[ -f "$S/driver/exit" ] && [ "$(driver_exit_code)" != 26 ]'
check "H: after a fresh lane starts, the restarted driver completes the run" \
  '[ "$(driver_exit_code)" = 0 ] && [ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = verified ] && [ "$(pyget "$S/stories/S2.json" "d[\"state\"]")" = verified ]'
check "H: the fresh lane ran the backend phases" '[ "$(ls "$C/lanes2/backend-dev/inbox/results" | grep -c "\.json$")" = 2 ]'
printf '{"kind":"stop"}\n' > "$C/stop.json"
for w in backend-dev qa-tester; do "$C/pool" assign --worker-id "$w" --envelope "$C/stop.json" >/dev/null; done
for f in "$C/lanes2/backend-dev/loop.json" "$C/lanes/qa-tester/loop.json"; do
  p="$(sed -n 's/^[[:space:]]*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" | head -1)"
  wait_for 15 eval "! kill -0 $p 2>/dev/null"
done

# ============================== case I ========================================
# A wrong worker_preference: S1 lists qa-tester first, and qa fails twice because
# nothing was built. The driver exits 21 with S1 held as blocked_needs_owner and
# a decision item carrying both failure texts. The owner fixes worker_preference,
# runs resolve --as retry, and the restarted driver routes the new first phase
# (backend) and completes.
setup_case i
mkdir -p "$S/driver"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["userStories"][0]["worker_preference"]=["qa-tester","backend-dev"]; json.dump(d,open(p,"w"))' "$C/prd.json"
printf 'S1 qa\n' > "$C/fail"
PC_MAX_STORIES=1 start_driver
wait_for 60 test -f "$S/driver/exit"
DI="$S/decisions/S1-blocked-qa.md"
check "I: qa failed twice -> exit 21, story held for the owner" \
  '[ "$(driver_exit_code)" = 21 ] && grep -q "failed in 2 of 2 attempt(s)" "$S/driver/exit" && [ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = blocked_needs_owner ] && [ "$(calls_for S1 qa)" = 2 ]'
check "I: the decision item carries both failure texts and the lane" \
  'grep -q "lane: qa-tester" "$DI" && grep -q "stub failure 1: qa" "$DI" && grep -q "stub failure 2: qa" "$DI"'
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["userStories"][0]["worker_preference"]=["backend-dev","qa-tester"]; json.dump(d,open(p,"w"))' "$C/prd.json"
rm -f "$C/fail"
"$PC" resolve --state "$S" --story S1 --as retry --prd "$C/prd.json" --note "build it first" > "$C/retry.out" 2>&1; rr=$?
check "I: resolve --as retry re-reads the phases from the prd" \
  '[ $rr = 0 ] && grep -q "phases:backend,qa next:backend" "$C/retry.out"'
PC_MAX_STORIES=1 start_driver
wait_for 60 eval '[ -f "$S/driver/exit" ] && [ "$(driver_exit_code)" != 21 ]'
check "I: the restarted driver routes the new first phase and completes" \
  '[ "$(driver_exit_code)" = 0 ] && [ "$(calls_for S1 backend)" = 1 ] && [ "$(calls_for S1 qa)" = 3 ] && [ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = verified ] && [ "$(pyget "$S/stories/S2.json" "d[\"state\"]")" = verified ]'
check "I: backend ran before the third qa attempt" \
  '[ "$(grep -n "^S1 backend " "$C/calls" | cut -d: -f1)" -lt "$(grep -n "^S1 qa " "$C/calls" | tail -1 | cut -d: -f1)" ]'
stop_lanes

# ============================== case J ========================================
# A regression gate fails because of a story the run already verified. Both
# stories verify and the gate comes due (exit 20). The parent records the failed
# gate naming S1; the conductor reopens S1. The restarted driver routes S1's
# implementing phase with the note, QA re-verifies it, the gate is due again,
# and after it passes the driver exits all-done with S2 listed as verified
# before S1 was reopened.
setup_case j
mkdir -p "$S/driver"
PC_GATE_EVERY=2 start_driver
wait_for 60 test -f "$S/driver/exit"
check "J: both stories verified and the gate came due (exit 20)" \
  '[ "$(driver_exit_code)" = 20 ] && [ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = verified ] && [ "$(pyget "$S/stories/S2.json" "d[\"state\"]")" = verified ]'
"$PC" gate result fail --state "$S" --story S1 --note "guard test outside the story suite flags S1" > "$C/gate.out" 2>&1; rg=$?
check "J: gate result fail --story reopens S1" \
  '[ $rg = 0 ] && grep -q "^REOPENED S1 from:verified phase:backend archived:2 verified-dependents:S2" "$C/gate.out" && grep -q "^GATE reopened S1" "$C/gate.out"'
PC_GATE_EVERY=2 start_driver
wait_for 60 eval '[ "$(grep -c " EXIT " "$S/driver/driver.log")" = 2 ]'
check "J: the restarted driver routed S1's implementing phase first, with the note" \
  'grep -q "REOPENED_FIRST S1@backend" "$S/driver/driver.log" && [ "$(calls_for S1 backend)" = 2 ] && grep -q "guard test outside the story suite flags S1" "$C/calls.prompts"'
check "J: QA re-verified S1; the gate is due again (exit 20)" \
  '[ "$(calls_for S1 qa)" = 2 ] && [ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = verified ] && [ "$(driver_exit_code)" = 20 ]'
check "J: S2 was not reopened or re-run" '[ "$(calls_for S2 backend)" = 1 ] && [ "$(calls_for S2 qa)" = 1 ]'
"$PC" gate result pass --state "$S" --note "guard test green" >/dev/null 2>&1
PC_GATE_EVERY=2 start_driver
wait_for 60 eval '[ "$(grep -c " EXIT " "$S/driver/driver.log")" = 3 ]'
check "J: driver exits all-done; the summary notes S2 was verified before S1 was reopened" \
  '[ "$(driver_exit_code)" = 0 ] && grep -q "^FINAL: verified 2, .*verified before S1 was reopened: S2" "$S/report.md"'
stop_lanes

# ============================== case K ========================================
# Three stories: S1 classifies from worker_preference, S2 matches no keyword and
# has no worker_preference (the overlay in run state classifies it), S3 is
# skipped. The driver gets the confirmed table. The run completes and FINAL
# lists the skip.
setup_case k
cat > "$C/prd.json" <<'PRD'
{"name":"e2e","userStories":[
 {"id":"S1","title":"First story","description":"first","priority":1,"passes":false,"dependsOn":[],
  "worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["S1 AC zero"]},
 {"id":"S2","title":"Write a poem","description":"verse","priority":2,"passes":false,"dependsOn":[],
  "acceptanceCriteria":["S2 AC zero"]},
 {"id":"S3","title":"Third story","description":"left out","priority":3,"passes":false,"dependsOn":[],
  "worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["S3 AC zero"]}
]}
PRD
cp "$C/prd.json" "$C/prd.before"
"$PC" classify --prd "$C/prd.json" --state "$S" --table "$C/table.tsv" > "$C/classify0.out" 2>&1; k0=$?
check "K: before the overlay, classify refuses the unclassified S2" '[ $k0 = 1 ] && grep -q "ERROR story S2 is unclassified" "$C/classify0.out"'
"$PC" overlay set --state "$S" --story S2 --sequence backend-dev,qa-tester >/dev/null 2>&1
"$PC" skip --state "$S" --story S3 --prd "$C/prd.json" --note "out of scope this run" > "$C/skip.out" 2>&1
"$PC" classify --prd "$C/prd.json" --state "$S" --table "$C/table.tsv" > "$C/classify1.out" 2>&1; k1=$?
check "K: with the overlay and the skip, classify passes" \
  '[ $k1 = 0 ] && grep -q "^OK S2 backend-dev,qa-tester (overlay)" "$C/classify1.out" && grep -q "^SKIPPED S3" "$C/classify1.out"'
mkdir -p "$S/driver"
bash "$DETACH" --logfile "$S/driver/detach.log" -- \
  sh "$DRIVER" --prd "$C/prd.json" --state "$S" --worktree "$WT" --table "$C/table.tsv" --interval 0.2
wait_for 60 test -f "$S/driver/exit"
check "K: driver exits all-done (0)" '[ "$(driver_exit_code)" = 0 ]'
check "K: S1 and S2 verified; S2 recorded classified_by overlay" \
  '[ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = verified ] && [ "$(pyget "$S/stories/S2.json" "d[\"state\"]")" = verified ] && [ "$(pyget "$S/stories/S2.json" "d[\"classified_by\"]")" = overlay ]'
check "K: S3 never ran" '[ "$(calls_for S3 backend)" = 0 ] && [ "$(pyget "$S/stories/S3.json" "d[\"state\"]")" = skipped ]'
check "K: FINAL counts two verified and lists the skip with its note" \
  'grep -q "^FINAL: verified 2, .*skipped S3 (out of scope this run)" "$S/report.md"'
check "K: the prd was not edited" 'cmp -s "$C/prd.json" "$C/prd.before"'
stop_lanes

# ============================== case L ========================================
# A sequence names a worker with no row in the confirmed table: the driver stops
# with exit 27 naming the worker instead of leaving the story in flight.
setup_case l
printf 'backend-dev\tclaude\tfake-model\tlow\n' > "$C/table-short.tsv"
mkdir -p "$S/driver"
bash "$DETACH" --logfile "$S/driver/detach.log" -- \
  sh "$DRIVER" --prd "$C/prd.json" --state "$S" --worktree "$WT" --table "$C/table-short.tsv" --interval 0.2
wait_for 30 test -f "$S/driver/exit"
check "L: driver exits 27 naming the worker with no lane" \
  '[ "$(driver_exit_code)" = 27 ] && grep -q "no lane: worker qa-tester" "$S/driver/exit"'
check "L: no phase ran and no story is in flight" '[ ! -s "$C/calls" ] && ! grep -qs in_flight "$S"/stories/*.json'
stop_lanes

# ============================== case M ========================================
# Early engine exit: S1's backend engine quits without a reply every time. The
# lane journals phase-exit; the driver logs EARLY_EXIT, routes the phase once
# more to the same lane (the restart in place), and after the second early exit
# holds S1 for the owner with exit 21 naming engine_exited_early. A long
# deadline is never waited out.
setup_case m
printf 'S1 backend\n' > "$C/early"
mkdir -p "$S/driver"
bash "$DETACH" --logfile "$S/driver/detach.log" -- \
  sh "$DRIVER" --prd "$C/prd.json" --state "$S" --worktree "$WT" --table "$C/table.tsv" --interval 0.2
wait_for 60 test -f "$S/driver/exit"
check "M: driver exits 21 naming engine_exited_early" \
  '[ "$(driver_exit_code)" = 21 ] && grep -q "phase S1/backend: engine_exited_early in 2 of 2 attempt(s)" "$S/driver/exit"'
check "M: the engine ran twice for S1/backend (one restart in place)" '[ "$(calls_for S1 backend)" = 2 ]'
check "M: the lane journalled two phase-exit events" \
  '[ "$(grep -c "\"event\":\"phase-exit\"" "$C/lanes/backend-dev/journal.jsonl")" = 2 ]'
check "M: each early exit has a tick line with story, phase and elapsed time" \
  '[ "$(grep -c "TICK: EARLY_EXIT S1/backend after [0-9]*s: engine_exited_early" "$S/driver/driver.log")" = 2 ]'
check "M: S1 is held for the owner and the decision item names engine_exited_early" \
  '[ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = blocked_needs_owner ] && grep -q engine_exited_early "$S/decisions/S1-blocked-backend.md"'
stop_lanes

# ============================== case N ========================================
# Stop mid-phase: S1's backend phase is in flight (the stub sleeps) when the
# parent runs `pipeline-conductor.sh stop`. The driver exits 29, S1 is marked
# interrupted at backend; the restarted driver routes S1 first with
# resumed_after_interrupt and the late handoff as prior_handoff, and the run
# completes.
setup_case n
printf '2\n' > "$C/sleep"
mkdir -p "$S/driver"
start_driver
wait_for 30 grep -q "ROUTED S1 backend" "$S/driver/driver.log"
bash "$PC" stop --state "$S" --note "owner stop" > "$C/stop.out" 2>&1
wait_for 30 test -f "$S/driver/exit"
check "N: stop asks the live driver through stop.json" 'grep -q "^STOP_REQUESTED " "$C/stop.out"'
check "N: the driver exits 29 stopped on request" '[ "$(driver_exit_code)" = 29 ] && [ ! -f "$S/driver/stop.json" ]'
check "N: the in-flight story is marked interrupted with phase and time" \
  '[ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = interrupted ] && [ "$(pyget "$S/stories/S1.json" "d[\"interrupted\"][\"phase\"]")" = backend ] && [ -n "$(pyget "$S/stories/S1.json" "d[\"interrupted\"][\"at\"]")" ]'
check "N: driver.log records the interrupt" 'grep -q "INTERRUPT rc=0: INTERRUPTED S1 backend" "$S/driver/driver.log"'
bash "$PC" report final --state "$S" > "$C/final.out" 2>&1
check "N: the summary lists the interrupted story" 'grep -q "interrupted 1,.*interrupted, routed first on the next driver start: S1 at backend" "$C/final.out"'
# the lane finishes the call it was in; its handoff lands after the stop
wait_for 30 eval '[ "$(lane_results backend-dev)" -ge 1 ]'
start_driver
wait_for 60 eval '[ -f "$S/driver/exit" ] && [ "$(driver_exit_code)" != 29 ]'
check "N: the restarted driver names the interrupted story first" 'grep -q "INTERRUPTED_FIRST S1@backend" "$S/driver/driver.log"'
check "N: the TICK line lists it until it is routed again" 'grep " TICK: " "$S/driver/driver.log" | grep -q "interrupted, routing first: S1 at backend"'
check "N: the re-routed envelope carries resumed_after_interrupt and the prior handoff" \
  '[ "$(pyget "$S/envelopes/S1-backend.json" "d.get(\"resumed_after_interrupt\")")" = True ] && [ -f "$(pyget "$S/envelopes/S1-backend.json" "d[\"prior_handoff\"]")" ] && "$PE" validate --kind envelope "$S/envelopes/S1-backend.json" >/dev/null 2>&1'
check "N: the run completes with both stories verified" \
  '[ "$(driver_exit_code)" = 0 ] && [ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = verified ] && [ "$(pyget "$S/stories/S2.json" "d[\"state\"]")" = verified ]'
check "N: S1 backend ran again after the stop, once" '[ "$(calls_for S1 backend)" = 2 ]'
check "N: the FINAL line no longer lists it as interrupted" 'grep -q "^FINAL: verified 2,.* interrupted 0," "$S/report.md" && ! grep -q "routed first on the next driver start" "$S/report.md"'
stop_lanes

echo "pipeline-e2e: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
