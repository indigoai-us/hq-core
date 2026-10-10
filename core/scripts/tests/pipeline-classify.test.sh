#!/usr/bin/env bash
# Tests for the classification and scheduling checks in core/scripts/pipeline-conductor.sh
# (fix pass 3): worker sequence validation, the classification overlay, lane
# coverage, unknown workers, the skip list, model_hint versus a table pin, the
# dependency lint, and park/unpark counts. bash 3.2 portable.
# shellcheck disable=SC2016  # check() evals single-quoted assertions on purpose
set -u
unset PC_WORKERS_ROOT PC_HQ PC_NOW PC_TABLE PC_PARK_CONFIRM HQ_SESSION_ID
HERE="$(cd "$(dirname "$0")" && pwd)"
PC="${PC_UNDER_TEST:-$HERE/../pipeline-conductor.sh}"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pc-classify.XXXXXX")" && pwd -P)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "PASS: $1"; else fail=$((fail+1)); echo "FAIL: $1"; fi; }
pyget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

# ---- fixtures: workers ----
W="$T/workers"
mkw() { mkdir -p "$W/$1"; printf '%s\n' "$2" > "$W/$1/worker.yaml"; }
mkw backend-dev 'worker:
  id: backend-dev
  type: CodeWorker'
mkw frontend-dev 'worker:
  id: frontend-dev
  type: CodeWorker'
mkw architect 'worker:
  id: architect
  type: CodeWorker'
mkw qa-tester 'worker:
  id: qa-tester
  type: OpsWorker'
# a verifier whose id names nothing: only worker.role says so
mkw gatekeeper 'worker:
  id: gatekeeper
  role: reviewer
  type: CodeWorker'
# role wins over an id that looks like a tester
mkw test-fixture-builder 'worker:
  id: test-fixture-builder
  role: implementer'
export PC_WORKERS_ROOT="$W" PC_NOW=1790000000 PC_HQ_ROOT="$T/hq"
mkdir -p "$T/hq" "$T/wt"

S="$T/state"
run() { "$PC" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }
both() { cat "$T/out" "$T/err"; }

cat > "$T/prd.json" <<'EOF'
{"name":"demo","userStories":[
 {"id":"A1","title":"code first","passes":false,"dependsOn":[],"files":["src/a.ts"],
  "worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["a"]},
 {"id":"A2","title":"qa first","passes":false,"dependsOn":[],"files":["src/b.ts","docs/b.md"],
  "worker_preference":["qa-tester","backend-dev"],"acceptanceCriteria":["b"]},
 {"id":"A3","title":"design doc","passes":false,"dependsOn":[],"files":["docs/design.md","plan.yaml"],
  "worker_preference":["architect"],"acceptanceCriteria":["c"]},
 {"id":"A4","title":"marked docs only","passes":false,"dependsOn":[],"files":["src/c.ts"],"docs_only":true,
  "worker_preference":["qa-tester"],"acceptanceCriteria":["d"]},
 {"id":"A5","title":"role says reviewer","passes":false,"dependsOn":[],"files":["lib/x.py"],
  "worker_preference":["gatekeeper","backend-dev"],"acceptanceCriteria":["e"]},
 {"id":"A6","title":"role says implementer","passes":false,"dependsOn":[],"files":["lib/y.py"],
  "worker_preference":["test-fixture-builder","qa-tester"],"acceptanceCriteria":["f"]},
 {"id":"A7","title":"typo","passes":false,"dependsOn":[],"worker_preference":["backend-devv","qa-tester"],
  "acceptanceCriteria":["g"]},
 {"id":"A8","title":"Write a poem","passes":false,"dependsOn":[],"acceptanceCriteria":["h"]}
]}
EOF

# ---- 1. sequence validation ----
run classify --prd "$T/prd.json" --state "$S" --story A1
check "seq: an implementer-first code story is accepted" '[ "$(rc)" = 0 ] && [ "$(head -1 "$T/out")" = "$(printf "backend\tbackend-dev")" ]'
run classify --prd "$T/prd.json" --state "$S" --story A2
check "seq: a code story that starts with a verifier is rejected naming story and worker" \
  '[ "$(rc)" = 1 ] && grep -q "story A2: its sequence qa-tester,backend-dev starts with qa-tester" "$T/err" && [ ! -f "$S/stories/A2.json" ]'
check "seq: the rejection suggests both fixes" 'grep -q "Prepend an implementer" "$T/err" && grep -q "docs_only" "$T/err" && grep -q "overlay set" "$T/err"'
run classify --prd "$T/prd.json" --state "$S" --story A3
check "seq: a docs-and-yaml story may start with the architect" '[ "$(rc)" = 0 ]'
check "seq: a one-worker sequence warns that architect and qa phases will not run" \
  'grep -q "WARN story A3: the sequence is one worker (architect); architect and qa phases will not run" "$T/err"'
run classify --prd "$T/prd.json" --state "$S" --story A3
check "seq: the warning prints once per story" '[ "$(rc)" = 0 ] && ! grep -q "one worker" "$T/err"'
run classify --prd "$T/prd.json" --state "$S" --story A4
check "seq: docs_only exempts a story with code files" '[ "$(rc)" = 0 ]'
run classify --prd "$T/prd.json" --state "$S" --story A5
check "seq: worker.role reviewer makes a neutral id a verifier" '[ "$(rc)" = 1 ] && grep -q "starts with gatekeeper (reviewer)" "$T/err"'
run classify --prd "$T/prd.json" --state "$S" --story A6
check "seq: worker.role implementer wins over a tester-looking id" '[ "$(rc)" = 0 ]'

# ---- 4. unknown workers ----
run classify --prd "$T/prd.json" --state "$S" --story A7
check "unknown: a worker with no worker.yaml is refused with the roots searched" \
  '[ "$(rc)" = 1 ] && grep -q "unknown worker backend-devv: no worker.yaml under $W" "$T/err"'
check "unknown: the nearest known id is suggested" 'grep -q "nearest known: backend-dev" "$T/err"'

# ---- 2. overlay ----
cp "$T/prd.json" "$T/prd.before"
run classify --prd "$T/prd.json" --state "$S" --story A8
check "overlay: a story no keyword matches is unclassified, with the overlay and skip named" \
  '[ "$(rc)" = 1 ] && grep -q "A8 is unclassified" "$T/err" && grep -q "overlay set" "$T/err" && grep -q "skip --state" "$T/err"'
cat > "$T/preflight.json" <<'EOF'
{"project":"demo","ordered_stories":[
 {"id":"A8","title":"Write a poem","primary_worker":"frontend-dev","worker_sequence":["frontend-dev","qa-tester"]},
 {"id":"A1","worker_sequence":["frontend-dev","backend-dev","qa-tester"]}
]}
EOF
run classify --prd "$T/prd.json" --state "$S" --story A8 --overlay "$T/preflight.json"
check "overlay: the preflight plan shape classifies the story" \
  '[ "$(rc)" = 0 ] && [ "$(pyget "$S/stories/A8.json" "\",\".join(p[\"worker\"] for p in d[\"phases\"])")" = frontend-dev,qa-tester ]'
check "overlay: stories/<id>.json records classified_by overlay" '[ "$(pyget "$S/stories/A8.json" "d[\"classified_by\"]")" = overlay ]'
check "overlay: it lives in <state>/overlay.json and the prd is not edited" \
  '[ -f "$S/overlay.json" ] && cmp -s "$T/prd.json" "$T/prd.before"'
rm -f "$S/stories/A1.json"
run classify --prd "$T/prd.json" --state "$S" --story A1
check "overlay: an overlay entry wins over worker_preference" \
  '[ "$(pyget "$S/stories/A1.json" "d[\"classified_by\"]")" = overlay ] && [ "$(pyget "$S/stories/A1.json" "d[\"phases\"][0][\"worker\"]")" = frontend-dev ]'
run overlay set --state "$S" --story A2 --sequence backend-dev,qa-tester
check "overlay set: prints the sequence" '[ "$(rc)" = 0 ] && grep -q "^OVERLAY A2 backend-dev,qa-tester" "$T/out"'
run overlay show --state "$S"
check "overlay show: lists every entry" \
  '[ "$(rc)" = 0 ] && python3 -c "import json,sys;d=json.load(open(\"$T/out\"));sys.exit(0 if d[\"A2\"][\"worker_sequence\"]==[\"backend-dev\",\"qa-tester\"] and \"A8\" in d else 1)"'
run classify --prd "$T/prd.json" --state "$S" --story A2
check "overlay set: fixes the rejected verifier-first story without a prd edit" '[ "$(rc)" = 0 ] && cmp -s "$T/prd.json" "$T/prd.before"'
printf '{"A7":["backend-dev","qa-tester"]}' > "$T/ov-map.json"
S2="$T/state-map"
run classify --prd "$T/prd.json" --state "$S2" --story A7 --overlay "$T/ov-map.json"
check "overlay: the plain {id: [workers]} shape is read too" '[ "$(rc)" = 0 ] && [ "$(pyget "$S2/stories/A7.json" "d[\"classified_by\"]")" = overlay ]'
run overlay set --state "$S" --story A2
check "overlay set: needs --sequence" '[ "$(rc)" = 2 ]'

# ---- 3. lane coverage ----
printf 'backend-dev\tclaude\tm-pin\tlow\n' > "$T/table.tsv"
S3="$T/state-lanes"
cat > "$T/prd-lanes.json" <<'EOF'
{"name":"lanes","userStories":[
 {"id":"L1","title":"Add REST endpoint","passes":false,"dependsOn":[],"acceptanceCriteria":["x"]},
 {"id":"L2","title":"b","passes":false,"dependsOn":[],"worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["y"]}
]}
EOF
run classify --prd "$T/prd-lanes.json" --state "$S3" --table "$T/table.tsv"
check "lanes: classify (all stories) refuses and lists every worker with no row" \
  '[ "$(rc)" = 1 ] && grep -q "ERROR no lane in the worker table $T/table.tsv for: architect (L1); qa-tester (L1,L2)" "$T/out"'
check "lanes: the check writes no story state" '[ -z "$(ls "$S3/stories")" ]'
printf 'backend-dev\tclaude\tm-pin\nqa-tester\tcodex\tgpt-x\narchitect\tclaude\tm-arch\n' > "$T/table-full.tsv"
run classify --prd "$T/prd-lanes.json" --state "$S3" --table "$T/table-full.tsv"
check "lanes: a full table passes; OK lines name the source" \
  '[ "$(rc)" = 0 ] && grep -q "^OK L1 architect,backend-dev,qa-tester (keywords)" "$T/out" && grep -q "^OK L2 backend-dev,qa-tester (worker_preference)" "$T/out"'
run classify --prd "$T/prd-lanes.json" --state "$S3" --story L2 --table "$T/table-full.tsv"
python3 - "$S3/stories/L2.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["current"]=1; json.dump(d,open(p,"w"))
PY
mkdir -p "$S3/handoffs"
printf '{"schema":"hq-phase-handoff/v1","story_id":"L2","phase":"backend","worker_id":"backend-dev","status":"passed","summary":"s","files_changed":[],"commits":[],"back_pressure":{"tests":"pass","lint":"skip","typecheck":"skip","build":"skip"},"context_for_next":"c","ac_evidence":[]}' > "$S3/handoffs/L2-backend.json"
: > "$T/pool.log"
run route --prd "$T/prd-lanes.json" --state "$S3" --story L2 --table "$T/table.tsv"
check "lanes: route refuses a phase whose worker has no row (exit 12, NO_LANE, nothing queued)" \
  '[ "$(rc)" = 12 ] && grep -q "^NO_LANE L2 qa qa-tester" "$T/out" && [ ! -s "$T/pool.log" ] && [ "$(pyget "$S3/stories/L2.json" "d[\"state\"]")" = queued ]'
S3b="$T/state-lanes-tick"
run tick --prd "$T/prd-lanes.json" --state "$S3b" --worktree "$T/wt" --table "$T/table.tsv"
check "lanes: tick prints NO_LANE for a new story whose sequence has a worker with no row" \
  '[ "$(rc)" = 0 ] && grep -q "^NO_LANE L1 architect architect" "$T/out" && [ ! -s "$T/pool.log" ]'

# ---- 6. model_hint versus a table pin ----
cat > "$T/prd-hint.json" <<'EOF'
{"name":"hint","userStories":[
 {"id":"H1","title":"a","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"model_hint":"opus","acceptanceCriteria":["x"]},
 {"id":"H2","title":"b","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"model_hint":"claude-opus-9-9","acceptanceCriteria":["y"]}
]}
EOF
S4="$T/state-hint"
run classify --prd "$T/prd-hint.json" --state "$S4" --story H1 --table "$T/table.tsv"
check "hint: a table pin wins; the hint is reported once as ignored" \
  '[ "$(rc)" = 0 ] && grep -q "story H1: model_hint opus: hint ignored, table pins m-pin" "$T/err" && [ "$(pyget "$S4/stories/H1.json" "d.get(\"model_hint\")")" = None ]'
run classify --prd "$T/prd-hint.json" --state "$S4" --story H1 --table "$T/table.tsv"
check "hint: not repeated on a second classify" '! grep -q "hint ignored" "$T/err"'
S5="$T/state-hint-nopin"
run classify --prd "$T/prd-hint.json" --state "$S5" --story H1
check "hint: with no pin a bare alias is ignored with a warning and never recorded" \
  'grep -q "model_hint opus is a bare alias and is ignored" "$T/err" && [ "$(pyget "$S5/stories/H1.json" "d.get(\"model_hint\")")" = None ]'
run classify --prd "$T/prd-hint.json" --state "$S5" --story H2
check "hint: with no pin a full model id is kept" '[ "$(pyget "$S5/stories/H2.json" "d.get(\"model_hint\")")" = claude-opus-9-9 ]'

# ---- 8. dependency lint ----
cat > "$T/prd-dep.json" <<'EOF'
{"name":"dep","userStories":[
 {"id":"D1","title":"harness","passes":false,"dependsOn":[],"worker_preference":["backend-dev","qa-tester"],
  "files":["tests/harness.ts"],"acceptanceCriteria":["the harness exercises the D3 service","it reads lib/schema.ts columns"]},
 {"id":"D2","title":"schema","passes":false,"dependsOn":[],"worker_preference":["backend-dev","qa-tester"],
  "files":["lib/schema.ts"],"acceptanceCriteria":["schema"]},
 {"id":"D3","title":"service","passes":false,"dependsOn":["D2"],"worker_preference":["backend-dev","qa-tester"],
  "files":["lib/service.ts"],"acceptanceCriteria":["uses lib/schema.ts"]},
 {"id":"D4","title":"ok","passes":false,"dependsOn":["D3"],"worker_preference":["backend-dev","qa-tester"],
  "acceptanceCriteria":["calls D3 and D30"]}
]}
EOF
run classify --prd "$T/prd-dep.json" --state "$T/state-dep"
check "deplint: a later story id and a later story's file in the ACs warn, with the dependsOn line" \
  '[ "$(rc)" = 0 ] && grep -q "WARN story D1 needs D2 (references lib/schema.ts, which only D2 declares) and D3 (names D3), but its dependsOn lacks them; suggested: \"dependsOn\": \[\"D2\", \"D3\"\]" "$T/out"'
check "deplint: an earlier story or a declared dependency does not warn" '! grep -q "WARN story D3 " "$T/out" && ! grep -q "WARN story D4 " "$T/out"'

# ---- 5. skip list ----
cat > "$T/prd-skip.json" <<'EOF'
{"name":"skip","userStories":[
 {"id":"K1","title":"one","passes":false,"dependsOn":[],"worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["x"]},
 {"id":"K2","title":"Write a poem","passes":false,"dependsOn":[],"acceptanceCriteria":["y"]},
 {"id":"K3","title":"three","passes":false,"dependsOn":["K1"],"worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["z"]},
 {"id":"K4","title":"four","passes":false,"dependsOn":["K3"],"worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["w"]}
]}
EOF
S6="$T/state-skip"
run skip --state "$S6" --story K2 --prd "$T/prd-skip.json" --note "no owner this week"
check "skip: writes skips.json and prints SKIPPED" \
  '[ "$(rc)" = 0 ] && grep -q "^SKIPPED K2" "$T/out" && [ "$(pyget "$S6/skips.json" "d[\"K2\"][\"note\"]")" = "no owner this week" ]'
run next --prd "$T/prd-skip.json" --state "$S6"
check "skip: a skipped story is not selected" '! grep -q K2 "$T/out" && grep -q K1 "$T/out"'
run classify --prd "$T/prd-skip.json" --state "$S6" --story K2
check "skip: classify does not exit on an unclassified skipped story" '[ "$(rc)" = 0 ] && grep -q "^SKIPPED K2" "$T/out"'
run classify --prd "$T/prd-skip.json" --state "$S6"
check "skip: classify (all) passes over it" '[ "$(rc)" = 0 ] && grep -q "^SKIPPED K2" "$T/out"'
run skip --state "$S6" --story K2 --prd "$T/prd-skip.json"
check "skip: repeating prints ALREADY" '[ "$(rc)" = 0 ] && grep -q "^ALREADY skipped K2" "$T/out"'
run skip --state "$S6" --story K1 --prd "$T/prd-skip.json"
check "skip: a story others depend on prints the stranded dependents and needs --force" \
  '[ "$(rc)" = 1 ] && grep -q "^SKIP_STRANDS K1 2: K3,K4" "$T/out" && grep -q -- "--force" "$T/err" && ! grep -q K1 "$S6/skips.json"'
run skip --state "$S6" --story K1 --prd "$T/prd-skip.json" --note "blocked upstream" --force
check "skip: --force skips it" '[ "$(rc)" = 0 ] && grep -q "^SKIPPED K1" "$T/out"'
run tick --prd "$T/prd-skip.json" --state "$S6" --worktree "$T/wt"
check "skip: tick routes nothing (both runnable stories skipped, the rest stranded)" '[ "$(rc)" = 0 ] && ! grep -q ROUTED "$T/out"'
run report final --state "$S6"
check "skip: FINAL lists each skip with its note and what it strands, outside the verified count" \
  'grep -q "^FINAL: verified 0, .*unfinished 0" "$T/out" && grep -q "skipped K1 (blocked upstream; strands K3, K4)" "$T/out" && grep -q "skipped K2 (no owner this week)" "$T/out"'
check "skip: each skip is in the decisions log" '[ "$(grep -c "\"action\": \"skip\"" "$S6/decisions.log")" = 2 ]'
run unskip --state "$S6" --story K1
check "unskip: restores the story to selection" '[ "$(rc)" = 0 ] && grep -q "^UNSKIPPED K1 not-started" "$T/out" && [ ! -f "$S6/stories/K1.json" ]'
run next --prd "$T/prd-skip.json" --state "$S6"
check "unskip: selected again" 'grep -q K1 "$T/out"'
run unskip --state "$S6" --story K1
check "unskip: repeating prints ALREADY" 'grep -q "^ALREADY unskipped K1" "$T/out"'

# ---- 9. park and unpark counts ----
python3 - "$T/prd-park.json" <<'PY'
import json, sys
st = [{"id": "P0", "title": "root", "passes": False, "dependsOn": [], "worker_preference": ["backend-dev"], "acceptanceCriteria": ["x"]}]
for i in range(1, 8):
    st.append({"id": "P%d" % i, "title": "t%d" % i, "passes": False, "dependsOn": ["P%d" % (i - 1)],
               "worker_preference": ["backend-dev"], "acceptanceCriteria": ["x"]})
st.append({"id": "Q1", "title": "free", "passes": False, "dependsOn": [], "worker_preference": ["backend-dev"], "acceptanceCriteria": ["x"]})
json.dump({"name": "park", "userStories": st}, open(sys.argv[1], "w"))
PY
S7="$T/state-park"
run park --state "$S7" --story P0 --prd "$T/prd-park.json" --note "wait"
check "park: prints the closure first and refuses more than PC_PARK_CONFIRM without --force" \
  '[ "$(rc)" = 1 ] && grep -q "^PARK_CLOSURE P0 7: P1,P2,P3,P4,P5,P6,P7" "$T/out" && grep -q "PC_PARK_CONFIRM=5" "$T/err" && [ ! -f "$S7/stories/P0.json" ]'
PC_PARK_CONFIRM=7 run park --state "$S7" --story P5 --prd "$T/prd-park.json" --note "small"
check "park: within PC_PARK_CONFIRM it parks without --force" '[ "$(rc)" = 0 ] && grep -q "^PARK_CLOSURE P5 2: P6,P7" "$T/out" && grep -q "^PARKED P5" "$T/out"'
run unpark --state "$S7" --story P5 --prd "$T/prd-park.json"
check "unpark: prints what it releases" '[ "$(rc)" = 0 ] && grep -q "^UNPARK_RELEASES P5 2: P6,P7" "$T/out"'
run park --state "$S7" --story P0 --prd "$T/prd-park.json" --note "wait" --force
check "park: --force parks the whole closure" \
  '[ "$(rc)" = 0 ] && grep -q "^PARKED P0" "$T/out" && [ "$(pyget "$S7/stories/P7.json" "d[\"state\"]")" = parked_dependency ] && [ ! -f "$S7/stories/Q1.json" ]'
check "park/unpark: each is in the decisions log with its count" \
  'python3 -c "import json,sys;r=[json.loads(l) for l in open(\"$S7/decisions.log\")];a=[x[\"action\"] for x in r];sys.exit(0 if a==[\"park\",\"unpark\",\"park\"] and len(r[2][\"closure\"])==7 and r[1][\"releases\"]==[\"P6\",\"P7\"] else 1)"'

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ $fail -eq 0 ]
