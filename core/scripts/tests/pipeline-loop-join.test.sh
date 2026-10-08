#!/usr/bin/env bash
# Regression test: a §8 phase envelope built by `pipeline-conductor.sh route`
# runs in a real `workflow-runner.mjs --loop` lane and comes back at its
# result_path as a §8 handoff that `pipeline-envelope.sh validate --kind
# handoff` and `pipeline-conductor.sh accept` both take.
#
# Before the fix the loop lane failed every §8 envelope with "agent() requires
# a non-empty string prompt" and wrote its own run record to result_path.
#
# Uses a FAKE claude binary (HQ_WORKFLOW_CLAUDE_BIN) that records the prompt it
# was given and replies with whatever the test put in $T/reply, and a stub
# conduct pool that queues the envelope the way conduct-pool.sh enqueues into a
# live loop lane (conduct-inbox.sh send). Covered:
#   1. route -> loop -> result_path is a valid handoff, accept prints NEXT
#   2. the prompt carries the literal acceptance criteria, constraints from
#      {state}/constraints.txt, story title/description, worktree, worker
#      identity and skill file paths, and the execute/foreground/git -C rules
#   3. a failing engine yields a valid handoff with status failed
#   4. an off-contract reply yields a valid handoff with status failed
#   5. the lane's own run record stays in inbox/results/
# bash 3.2 portable.
set -u
unset HQ_SPAWN_COMPANY HQ_SESSION_ID HQ_PARENT_SESSION_ID HQ_SPAWN_TASK HQ_CONDUCT_RUN_DIR PC_WORKERS_ROOT
# Isolation: this suite never inherits the caller's session. Its own session id,
# and (below) its own HQ_ROOT with workspace/sessions and run dirs under a temp root,
# keep every pool call, lane and signal inside what this test started.
export HQ_SESSION_ID="test-pipeline-loop-join-$$"

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
PC="$SCRIPTS/pipeline-conductor.sh"
PE="$SCRIPTS/pipeline-envelope.sh"
RUNNER="$SCRIPTS/workflow-runner.mjs"
INBOX_SH="$SCRIPTS/conduct-inbox.sh"

pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "PASS: $1"; else fail=$((fail+1)); echo "FAIL: $1"; fi; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pipeline-loop-join.XXXXXX")" && pwd -P)"
LANE_PID=""
cleanup() {
  [ -n "$LANE_PID" ] && kill "$LANE_PID" 2>/dev/null
  [ -n "${KEEP:-}" ] || rm -rf "$T"
}
trap cleanup EXIT

# ---- synthetic HQ root with one worker ----
HQ="$T/hq"
mkdir -p "$HQ/.claude" "$HQ/personal/workers/public/dev-team/backend-dev/skills" "$HQ/core/workers" "$T/bin" "$T/rec"
printf '{}\n' > "$HQ/.claude/settings.json"
W="$HQ/personal/workers/public/dev-team/backend-dev"
cat > "$W/worker.yaml" <<'EOF'
worker:
  id: backend-dev
  name: "Backend Dev"
  description: "Builds APIs and services"
skills:
  - id: build-api
    file: skills/build-api.md
verification:
  approval_required: false
instructions: |
  Prefer small commits. INSTR-MARKER-42.
EOF
printf '# build-api\n' > "$W/skills/build-api.md"
mkdir -p "$HQ/personal/workers/public/dev-team/qa-tester"
printf 'worker:\n  id: qa-tester\n  name: "QA Tester"\n' > "$HQ/personal/workers/public/dev-team/qa-tester/worker.yaml"

# ---- fake claude: record prompt, reply with $T/reply or fail ----
cat > "$T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in -p) prompt="$2"; shift 2 ;; *) shift ;; esac
done
n=$(ls "$FAKE_T/rec" | wc -l | tr -d ' ')
printf '%s' "$prompt" > "$FAKE_T/rec/prompt.$n"
if [ -f "$FAKE_T/fail" ]; then echo "fake claude: failing on purpose" >&2; exit 3; fi
python3 -c 'import json,sys; print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":open(sys.argv[1]).read()}))' "$FAKE_T/reply"
FAKE
chmod +x "$T/bin/claude"

# ---- stub pool: queue the envelope into the live loop lane ----
LANE="$T/lane"
mkdir -p "$LANE"
cat > "$T/pool" <<EOF
#!/usr/bin/env bash
env=""
while [ \$# -gt 0 ]; do case "\$1" in --envelope) env="\$2"; shift 2;; *) shift;; esac; done
bash "$INBOX_SH" send --run-dir "$LANE" --text "\$(cat "\$env")" >/dev/null || exit 1
# the real enqueue answer: conduct-pool.sh assign prints this for a live loop lane
printf '{"action":"enqueue","worker_id":"stub","pid":%s,"queued":"%s/inbox/pending","queue_depth":1}\n' "\$PPID" "$LANE"
EOF
chmod +x "$T/pool"

# ---- worktree + prd + state ----
# The runner only runs agents inside the HQ root; run worktrees live under
# workspace/worktrees/<project>/ (the conductor refuses a --worktree under repos/).
WT="$HQ/workspace/worktrees/demo/wt"; mkdir -p "$WT"; git -C "$WT" init -q
cat > "$T/prd.json" <<'EOF'
{"name":"demo","userStories":[
 {"id":"S1","title":"Add the widget endpoint","description":"DESC-MARKER: expose GET /widgets","priority":1,"passes":false,
  "dependsOn":[],"worker_preference":["backend-dev","qa-tester"],
  "acceptanceCriteria":["AC-ONE: GET /widgets returns 200","AC-TWO: the list is sorted by name"]}
]}
EOF
S="$T/state"
mkdir -p "$S"
printf 'Commit only to the feature branch\n\nNever push or deploy\n' > "$S/constraints.txt"

export HQ_ROOT="$HQ" PC_HQ_ROOT="$HQ" PC_POOL="$T/pool" FAKE_T="$T"
export HQ_WORKFLOW_CLAUDE_BIN="$T/bin/claude" HQ_WORKFLOW_CLAUDE_EXEC_MODEL="fake-model"
export HQ_WORKFLOW_CPU_CHECK=0 HQ_WORKFLOW_LOOP_POLL_MS=50 HQ_CONDUCT_ENGINE=claude

wait_file() { i=0; while [ $i -lt 300 ]; do [ -s "$1" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
pyget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

node "$RUNNER" --loop --quiet --run-dir "$LANE" > "$T/lane.out" 2> "$T/lane.err" &
LANE_PID=$!

"$PC" classify --prd "$T/prd.json" --state "$S" --story S1 --worktree "$WT" >/dev/null

# ---- 1. route -> loop -> valid handoff -> accept ----
cat > "$T/reply" <<'EOF'
Done. Here is the handoff:
```json
{"schema":"hq-phase-handoff/v1","story_id":"S1","phase":"backend","worker_id":"backend-dev","status":"passed",
 "summary":"added endpoint","files_changed":["src/widgets.ts"],"commits":["abc123"],
 "back_pressure":{"tests":"pass","lint":"pass","typecheck":"pass","build":"skip"},
 "context_for_next":"endpoint at /widgets",
 "ac_evidence":[{"index":0,"met":true,"evidence":"widgets.test.ts"},{"index":1,"met":true,"evidence":"widgets.test.ts sort case"}]}
```
EOF
"$PC" route --prd "$T/prd.json" --state "$S" --story S1 > "$T/out" 2> "$T/err"
check "route queues the backend envelope" 'grep -q "ROUTED S1 backend" "$T/out"'
ENV="$S/envelopes/S1-backend.json"
H="$S/handoffs/S1-backend.json"
check "envelope carries constraints from constraints.txt" \
  '[ "$(pyget "$ENV" "json.dumps(d.get(\"constraints\"))")" = "[\"Commit only to the feature branch\", \"Never push or deploy\"]" ]'
check "envelope carries story_title and story_description" \
  '[ "$(pyget "$ENV" "d.get(\"story_title\")")" = "Add the widget endpoint" ] && pyget "$ENV" "d.get(\"story_description\")" | grep -q DESC-MARKER'
check "envelope with the new optional fields validates" '"$PE" validate --kind envelope "$ENV" >/dev/null 2>&1'
wait_file "$H"
check "result_path holds a valid section 8 handoff" '"$PE" validate --kind handoff "$H" >/dev/null 2>&1'
check "handoff is the engine reply (passed, ac_evidence kept)" \
  '[ "$(pyget "$H" "d[\"status\"]")" = passed ] && [ "$(pyget "$H" "len(d[\"ac_evidence\"])")" = 2 ]'
"$PC" accept --state "$S" --story S1 --handoff "$H" > "$T/out" 2> "$T/err"
check "accept takes the lane-written handoff" 'grep -q "NEXT S1 qa" "$T/out"'
check "lane run record stays in inbox/results" '[ "$(ls "$LANE/inbox/results" | grep -c "\.json$")" -ge 1 ] && grep -q "\"handoff\"" "$LANE"/inbox/results/*.json'

# ---- 2. prompt contents ----
P="$T/rec/prompt.0"
check "prompt received by the engine" '[ -s "$P" ]'
check "prompt has each literal acceptance criterion" 'grep -qF "0. AC-ONE: GET /widgets returns 200" "$P" && grep -qF "1. AC-TWO: the list is sorted by name" "$P"'
check "prompt has the constraints verbatim" 'grep -qF -- "- Commit only to the feature branch" "$P" && grep -qF -- "- Never push or deploy" "$P"'
check "prompt has story title, description, id and phase" 'grep -qF "Add the widget endpoint" "$P" && grep -qF "DESC-MARKER" "$P" && grep -qF "Story id: S1" "$P" && grep -qF "Phase: backend" "$P"'
check "prompt names the worker, its instructions and skill file path" \
  'grep -qF "Backend Dev" "$P" && grep -qF "Builds APIs and services" "$P" && grep -qF "INSTR-MARKER-42" "$P" && grep -qF "$W/skills/build-api.md" "$P"'
check "prompt names the worktree and git -C commit rule" 'grep -qF "Working directory (worktree): $WT" "$P" && grep -qF "git -C $WT" "$P"'
check "prompt says execute, foreground gates, and handoff-only reply" \
  'grep -q "Execute" "$P" && grep -q "FOREGROUND" "$P" && grep -qF "hq-phase-handoff/v1" "$P" && grep -q "ac_evidence" "$P"'
check "first phase prompt says there is no incoming handoff" 'grep -q "None: this is the first phase" "$P"'

# ---- 3. failing engine -> failed handoff ----
touch "$T/fail"
"$PC" route --prd "$T/prd.json" --state "$S" --story S1 > "$T/out" 2> "$T/err"
HQA="$S/handoffs/S1-qa.json"
wait_file "$HQA"
check "qa prompt points at the incoming backend handoff" 'grep -qF "$H" "$T/rec/prompt.1"'
check "failing engine: result_path is a valid handoff" '"$PE" validate --kind handoff "$HQA" >/dev/null 2>&1'
check "failing engine: status failed with the reason" \
  '[ "$(pyget "$HQA" "d[\"status\"]")" = failed ] && pyget "$HQA" "d[\"summary\"]" | grep -q "engine error"'
"$PC" accept --state "$S" --story S1 --handoff "$HQA" > "$T/out" 2> "$T/err"; arc=$?
check "accept takes the failed handoff and requeues the phase" '[ $arc = 1 ] && grep -q "PHASE_FAILED S1 qa" "$T/out"'

# ---- 4. off-contract reply -> failed handoff ----
rm -f "$T/fail" "$HQA"
printf 'I looked at it and everything seems fine.\n' > "$T/reply"
"$PC" route --prd "$T/prd.json" --state "$S" --story S1 > "$T/out" 2> "$T/err"
wait_file "$HQA"
check "off-contract reply: result_path is a valid handoff" '"$PE" validate --kind handoff "$HQA" >/dev/null 2>&1'
check "off-contract reply: status failed, reason in notes" \
  '[ "$(pyget "$HQA" "d[\"status\"]")" = failed ] && pyget "$HQA" "d[\"notes\"]" | grep -q "normalize"'

cp "$HQA" "$T/offcontract.json"
"$PC" accept --state "$S" --story S1 --handoff "$HQA" > "$T/out" 2> "$T/err"
check "accept requeues after the off-contract handoff" 'grep -q "PHASE_FAILED S1 qa" "$T/out"'

# ---- 5. reply for the wrong phase -> failed handoff ----
rm -f "$HQA"
printf '{"schema":"hq-phase-handoff/v1","story_id":"S1","phase":"backend","worker_id":"backend-dev","status":"passed","summary":"s","files_changed":[],"commits":[],"back_pressure":{"tests":"pass","lint":"pass","typecheck":"pass","build":"pass"},"context_for_next":""}' > "$T/reply"
"$PC" route --prd "$T/prd.json" --state "$S" --story S1 > "$T/out" 2> "$T/err"
wait_file "$HQA"
check "mismatched phase in reply: failed handoff naming the mismatch" \
  '[ "$(pyget "$HQA" "d[\"status\"]")" = failed ] && [ "$(pyget "$HQA" "d[\"phase\"]")" = qa ] && pyget "$HQA" "d[\"notes\"]" | grep -q "does not match"'

check "lane still alive after all phases" 'kill -0 "$LANE_PID" 2>/dev/null'

echo "pipeline-loop-join: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
