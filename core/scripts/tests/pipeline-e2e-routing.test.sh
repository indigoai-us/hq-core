#!/usr/bin/env bash
# End-to-end tests for pipeline routing across repos and the story-level go,
# with a stub engine (no model calls).
#
# Real pieces: workflow-runner.mjs --loop lanes, conduct-pool.sh, the confirmed
# worker table, pipeline-conductor.sh (worktree, tick, go), pipeline-envelope.sh
# and pipeline-driver.sh launched through hq-detach.sh. Stub: the claude binary.
# In a backend phase it records the worktree's commit log, then commits
# "<story> backend" in the envelope's worktree.
#
# Case K: a prd lists two repos; each repo has a story and a dependent story.
#   One feature-branch worktree per repo is cut with `worktree --shared`; the
#   driver gets both as --worktree <repo>=<dir>. Every phase runs in the
#   worktree of its story's repo, the dependent story's phase sees its
#   dependency's commit, and the driver exits 0.
# Case L: a release story on qa-tester (approval_required false) is held
#   awaiting_go; the independent story completes; the driver exits 21 naming
#   it, driver.log TICK lines and report.md FINAL list it. After `go`, the
#   restarted driver runs it and exits 0.
# bash 3.2 portable.
set -u
unset HQ_SPAWN_COMPANY HQ_SESSION_ID HQ_PARENT_SESSION_ID HQ_PIPELINE_DECISIONS_FILE HQ_WORKFLOW_LANE \
  CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID HQ_WORKFLOW_PHASE_DEADLINE_SECS \
  HQ_CONDUCT_RUN_DIR HQ_CONDUCT_ENGINE PC_WORKERS_ROOT PC_POOL PC_ENVELOPE PC_NOW PC_MAX_STORIES
# Isolation: its own session id and HQ root; it touches only lanes it started.
export HQ_SESSION_ID="test-pipeline-e2e-routing-$$"

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
RUNNER="$SCRIPTS/workflow-runner.mjs"
POOL_SH="$SCRIPTS/conduct-pool.sh"
PC="$SCRIPTS/pipeline-conductor.sh"
TABLE="$SCRIPTS/pipeline-worker-table.sh"
DRIVER="$SCRIPTS/pipeline-driver.sh"
DETACH="$SCRIPTS/hq-detach.sh"

pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pipeline-e2e-routing.XXXXXX")" && pwd -P)"
PIDS=""
cleanup() {
  for f in "$T"/case-*/lanes/*/loop.json; do
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
pyget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }
mkrepo() { mkdir -p "$1" && git -C "$1" init -q -b main && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base; }

HQ="$T/hq"
mkdir -p "$HQ/.claude" "$HQ/workspace/sessions" "$HQ/core/workers" "$T/bin"
printf '{}\n' > "$HQ/.claude/settings.json"
for w in backend-dev qa-tester; do
  mkdir -p "$HQ/personal/workers/public/dev-team/$w"
  printf 'worker:\n  id: %s\n  name: "%s"\n  description: "test worker"\nverification:\n  approval_required: false\n' \
    "$w" "$w" > "$HQ/personal/workers/public/dev-team/$w/worker.yaml"
done

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
wt="$(printf '%s\n' "$prompt" | sed -n 's/^- Working directory (worktree): //p' | head -1)"
worker="$(printf '%s\n' "$prompt" | sed -n 's/^You are the `\([^`]*\)` worker.*/\1/p' | head -1)"
printf '%s %s %s %s\n' "$sid" "$phase" "$worker" "$wt" >> "$FAKE_REC"
if [ "$phase" = backend ]; then
  git -C "$wt" log --format=%s > "$FAKE_REC.seen-$sid" 2>&1
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$sid backend" >> "$FAKE_REC.git" 2>&1
fi
python3 - "$sid" "$phase" "$worker" "$prompt" <<'PY'
import json, re, sys
sid, phase, worker, prompt = sys.argv[1:5]
acs = re.findall(r"^(\d+)\. (.*)$", prompt.split("## Acceptance criteria", 1)[-1].split("##", 1)[0], re.M)
h = {"schema": "hq-phase-handoff/v1", "story_id": sid, "phase": phase, "worker_id": worker,
     "status": "passed", "summary": "stub did %s" % phase, "files_changed": [], "commits": [],
     "back_pressure": {"tests": "pass", "lint": "pass", "typecheck": "pass", "build": "skip"},
     "context_for_next": "", "ac_evidence": [{"index": int(i), "met": True, "evidence": "stub check %s" % i,
                                              "criterion": c} for i, c in acs]}
print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": json.dumps(h)}))
PY
FAKE
chmod +x "$T/bin/claude"

export HQ_ROOT="$HQ" PC_HQ_ROOT="$HQ"
export HQ_WORKFLOW_CLAUDE_BIN="$T/bin/claude" HQ_WORKFLOW_CPU_CHECK=0 HQ_WORKFLOW_LOOP_POLL_MS=50
export PC_GATE_EVERY=50 PC_MAX_STORIES=2
# worktrees live under the HQ root, as they do in a real run (workspace/), so lanes may cd into them
export PC_WORKTREE_ROOT="$HQ/workspace/worktrees"

setup_lanes() { # setup_lanes <name>: pool wrapper, worker table and one loop lane per worker
  SID="e2e-routing-$1"
  mkdir -p "$C/lanes" "$S/driver"
  export FAKE_REC="$C/calls"; : > "$FAKE_REC"
  printf 'backend-dev\tclaude\tfake-model\tlow\nqa-tester\tclaude\tfake-model\tlow\n' > "$C/table.tsv"
  bash "$TABLE" --confirmed "$C/table.tsv" "$C/prd.json" > "$C/lanes.env"
  printf '#!/usr/bin/env bash\nexec bash "%s" --session-id "%s" "$@"\n' "$POOL_SH" "$SID" > "$C/pool"
  chmod +x "$C/pool"
  export PC_POOL="$C/pool"
  for w in backend-dev qa-tester; do
    lane="$C/lanes/$w"; mkdir -p "$lane"
    exports="$(sed -n "/^# lane $w (/,/^# lane /p" "$C/lanes.env" | grep '^export ')"
    ( eval "$exports"; exec node "$RUNNER" --loop --quiet --run-dir "$lane" >> "$lane.out" 2>> "$lane.err" ) &
    pid=$!; PIDS="$PIDS $pid"
    wait_for 10 test -f "$lane/loop.json"
    "$C/pool" assign --worker-id "$w" >/dev/null
    "$C/pool" record --worker-id "$w" --subagent-id "loop-$w" --status waiting --pid "$pid" --run-dir "$lane" >/dev/null
  done
}
stop_lanes() {
  printf '{"kind":"stop"}\n' > "$C/stop.json"
  for w in backend-dev qa-tester; do "$C/pool" assign --worker-id "$w" --envelope "$C/stop.json" >/dev/null; done
  for w in backend-dev qa-tester; do
    p="$(sed -n 's/^[[:space:]]*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$C/lanes/$w/loop.json" | head -1)"
    wait_for 15 eval "! kill -0 $p 2>/dev/null"
  done
}
driver_exit_code() { [ -f "$S/driver/exit" ] && cut -d' ' -f1 "$S/driver/exit"; }
state_of() { pyget "$S/stories/$1.json" 'd["state"]'; }
ran_in() { # ran_in <story> <worktree>: every recorded phase of the story ran in that worktree
  grep "^$1 " "$C/calls" | grep -q . && ! grep "^$1 " "$C/calls" | grep -v " $2\$" | grep -q .
}

# ============================== case K ========================================
C="$T/case-k"; S="$C/state"; mkdir -p "$S"
RA="$HQ/repos/private/alpha"; RB="$HQ/repos/private/beta"; mkrepo "$RA"; mkrepo "$RB"
cat > "$C/prd.json" <<JSON
{"name":"routing","metadata":{"repos":["$RA","$RB"]},"userStories":[
 {"id":"A1","title":"alpha first","priority":1,"passes":false,"dependsOn":[],"files":["alpha/src/a.ts"],
  "worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["A1 works"]},
 {"id":"A2","title":"alpha dependent","priority":2,"passes":false,"dependsOn":["A1"],"files":["alpha/src/b.ts"],
  "worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["A2 works"]},
 {"id":"B1","title":"beta first","priority":1,"passes":false,"dependsOn":[],"repoPath":"$RB",
  "worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["B1 works"]},
 {"id":"B2","title":"beta dependent","priority":2,"passes":false,"dependsOn":["B1"],"files":["beta/x.ts"],
  "worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["B2 works"]}
]}
JSON
WA="$(bash "$PC" worktree --state "$S" --repo "$RA" --shared --prd "$C/prd.json" 2>"$C/cut-a.err")"
WB="$(bash "$PC" worktree --state "$S" --repo "$RB" --shared --prd "$C/prd.json" 2>"$C/cut-b.err")"
check "K: one feature-branch worktree per repo, cut from main" \
  '[ -d "$WA" ] && [ -d "$WB" ] && grep -q "^CUT feature/routing from main " "$C/cut-a.err" && grep -q "^CUT feature/routing from main " "$C/cut-b.err"'
setup_lanes k
bash "$DETACH" --logfile "$S/driver/detach.log" -- \
  sh "$DRIVER" --prd "$C/prd.json" --state "$S" --worktree "$RA=$WA" --worktree "$RB=$WB" --interval 0.2
wait_for 90 test -f "$S/driver/exit"
check "K: driver exits 0 with every story verified" \
  '[ "$(driver_exit_code)" = 0 ] && [ "$(state_of A1)" = verified ] && [ "$(state_of A2)" = verified ] && [ "$(state_of B1)" = verified ] && [ "$(state_of B2)" = verified ]'
check "K: alpha stories ran only in the alpha worktree" 'ran_in A1 "$WA" && ran_in A2 "$WA"'
check "K: beta stories ran only in the beta worktree" 'ran_in B1 "$WB" && ran_in B2 "$WB"'
check "K: the dependent story's phase saw its dependency's commit" \
  'grep -qx "A1 backend" "$C/calls.seen-A2" && grep -qx "B1 backend" "$C/calls.seen-B2"'
check "K: each repo's feature branch holds its two stories in dependency order" \
  '[ "$(git -C "$RA" log --format=%s feature/routing | head -2 | tr "\n" ,)" = "A2 backend,A1 backend," ] && [ "$(git -C "$RB" log --format=%s feature/routing | head -2 | tr "\n" ,)" = "B2 backend,B1 backend," ]'
check "K: no story's commit landed in the other repo" '! git -C "$RA" log --all --format=%s | grep -q "^B" && ! git -C "$RB" log --all --format=%s | grep -q "^A"'
stop_lanes

# ============================== case L ========================================
C="$T/case-l"; S="$C/state"; mkdir -p "$S"
# the run worktree sits under workspace/worktrees, not repos/: the conductor refuses a --worktree under repos/
WL="$HQ/workspace/worktrees/release/gamma"; mkrepo "$WL"
cat > "$C/prd.json" <<'JSON'
{"name":"release","userStories":[
 {"id":"S1","title":"feature","priority":1,"passes":false,"dependsOn":[],
  "worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["S1 works"]},
 {"id":"R1","title":"release check","priority":2,"passes":false,"dependsOn":[],
  "worker_preference":["qa-tester"],"acceptanceCriteria":["Smoke test production after the release"]}
]}
JSON
setup_lanes l
start_l() { bash "$DETACH" --logfile "$S/driver/detach.log" -- sh "$DRIVER" --prd "$C/prd.json" --state "$S" --worktree "$WL" --interval 0.2; }
start_l
wait_for 60 test -f "$S/driver/exit"
check "L: the release story is held awaiting_go and never ran" '[ "$(state_of R1)" = awaiting_go ] && ! grep -q "^R1 " "$C/calls"'
check "L: the independent story completed" '[ "$(state_of S1)" = verified ]'
check "L: driver exits 21 naming the story awaiting go" '[ "$(driver_exit_code)" = 21 ] && grep -q "awaiting go: R1" "$S/driver/exit"'
check "L: driver.log TICK lines list the awaiting_go story" 'grep " TICK: " "$S/driver/driver.log" | grep -q "awaiting go: R1"'
check "L: report.md FINAL lists it" 'grep -q "^FINAL: .*awaiting go 1,.*awaiting go: R1" "$S/report.md"'
bash "$PC" go --state "$S" --story R1 > "$C/go.out" 2>&1
check "L: go releases it" 'grep -q "^GO R1" "$C/go.out" && [ "$(state_of R1)" = queued ]'
start_l
wait_for 60 eval '[ -f "$S/driver/exit" ] && [ "$(driver_exit_code)" != 21 ]'
check "L: the restarted driver runs it and the run completes" \
  '[ "$(driver_exit_code)" = 0 ] && [ "$(state_of R1)" = verified ] && [ "$(grep -c "^R1 qa " "$C/calls")" = 1 ]'
stop_lanes

echo "pipeline-e2e-routing: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
