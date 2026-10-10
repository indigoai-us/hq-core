#!/usr/bin/env bash
# Tests for core/scripts/pipeline-conductor.sh (bash 3.2 portable).
# shellcheck disable=SC2016,SC2034  # check() evals single-quoted assertions on purpose
# Uses a fake hq executable (logs every lanes call, copies enqueued envelopes)
# and the real pipeline-envelope.sh validator.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PC="${PC_UNDER_TEST:-$HERE/../pipeline-conductor.sh}"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pc-test.XXXXXX")" && pwd -P)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
cd "$T" || exit 1  # never run git against the caller's checkout
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ---- fixtures ----
mkdir -p "$T/queued" "$T/workers" "$T/bin" "$T/hq/core/scripts"
: > "$T/lanes.txt"
cat > "$T/hq/core/scripts/hq-session.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in current) printf 'test-session\n' ;; *company_slug*) printf 'indigo\n' ;; esac
EOF
chmod +x "$T/hq/core/scripts/hq-session.sh"
cat > "$T/bin/hq" <<EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$T/hq.log"
printf '%s\n' "\$*" >> "$T/pool.log"
case "\$1 \$2" in
  'lanes create')
    has_brief=false; for arg in "\$@"; do [ "\$arg" = --brief-file ] && has_brief=true; done
    if [ "\$has_brief" != true ]; then printf "error: required option '--brief-file <path>' not specified\\n" >&2; exit 1; fi
    rc=\$(cat "$T/pool.rc" 2>/dev/null || echo 0)
    worker=''; project=''; company=''; while [ \$# -gt 0 ]; do case "\$1" in --worker) worker="\$2"; shift 2;; --project) project="\$2"; shift 2;; --company) company="\$2"; shift 2;; *) shift;; esac; done
    if [ "\$rc" = 3 ]; then printf '{"ok":false,"error":"admission_denied"}\\n'; exit 0; fi
    if [ "\$rc" = 4 ]; then printf '{"ok":false,"error":"capacity_reached"}\\n'; exit 0; fi
    lane="lane-\$worker-\$(wc -l < "$T/lanes.txt")"
    printf '%s\\n' "\$lane" >> "$T/lanes.txt"
    printf '"company":{"slug":"%s"},"project_id":"%s","worker":"%s"' "\$company" "\$project" "\$worker" > "$T/owner.\$lane"
    printf '{"ok":true,"lane_id":"%s"}\\n' "\$lane" ;;
  'lanes enqueue')
    envelope=''; while [ \$# -gt 0 ]; do [ "\$1" = --envelope ] && { envelope="\$2"; shift 2; continue; }; shift; done
    if [ -z "\$envelope" ]; then printf "error: required option '--envelope <file>' not specified\\n" >&2; exit 1; fi
    answer=\$(cat "$T/pool.answer" 2>/dev/null || echo enqueue)
    if [ "\$answer" != enqueue ]; then printf '{"ok":false,"error":"loop_not_running"}\\n'; exit 0; fi
    cp "\$envelope" "$T/queued/"
    printf '{\\n  "ok": true,\\n  "action": "enqueue"\\n}\\n' ;;
  'lanes interrupt')
    story=''; phase=''; while [ \$# -gt 0 ]; do case "\$1" in --story) story="\$2"; shift 2;; --phase) phase="\$2"; shift 2;; *) shift;; esac; done
    answer=\$(cat "$T/pool.answer" 2>/dev/null || echo enqueue)
    if [ "\$answer" = picked_up ] || [ "\$story" = I2 ]; then printf '{"ok":true,"withdrawn":[],"already_picked_up":["%s-%s"]}\\n' "\$story" "\$phase"
    else printf '{"ok":true,"withdrawn":["%s-%s"],"already_picked_up":[]}\\n' "\$story" "\$phase"; fi ;;
  'lanes stop') touch "$T/stopped.\$3"; printf '{"ok":true}\\n' ;;
  'lanes list')
    printf '['; sep=''
    if [ -f "$T/lanes.txt" ]; then while IFS= read -r lane; do
      state=waiting; [ -f "$T/stopped.\$lane" ] && state=stopped
      owner=\$(cat "$T/owner.\$lane")
      printf '%s{"lane_id":"%s",%s,"loop":{"state":"%s","queue_depth":0}}' "\$sep" "\$lane" "\$owner" "\$state"; sep=,
    done < "$T/lanes.txt"; fi
    printf ']\\n' ;;
  'lanes questions') printf '[]\\n' ;;
  *) printf '{"ok":false,"error":"unexpected_call"}\\n'; exit 1 ;;
esac
EOF
chmod +x "$T/bin/hq"
mkw() { mkdir -p "$T/workers/$1"; printf '%s\n' "$2" > "$T/workers/$1/worker.yaml"; }
mkw backend-dev 'worker:
  id: backend-dev
verification:
  approval_required: false'
mkw qa-tester 'worker:
  id: qa-tester'
mkw gated-dev 'worker:
  id: gated-dev
verification:
  approval_required: true'
mkw checkpoint-dev 'worker:
  id: checkpoint-dev
verification:
  approval_required: false
  human_checkpoints:
    - before_deploy'

export PC_HQ="$T/bin/hq" PC_WORKERS_ROOT="$T/workers" PC_NOW=1790000000 PC_HQ_ROOT="$T/hq"
mkdir -p "$T/hq" "$T/wt"

cat > "$T/prd.json" <<'EOF'
{"name":"demo","userStories":[
 {"id":"S1","title":"one","priority":2,"passes":false,"dependsOn":[],"worker_preference":["backend-dev","qa-tester"],
  "acceptanceCriteria":["A one","A two"]},
 {"id":"S2","title":"two","priority":1,"passes":false,"dependsOn":[],"worker_preference":["backend-dev","qa-tester"],
  "acceptanceCriteria":["B one"]},
 {"id":"S3","title":"three","priority":0,"passes":false,"dependsOn":["S4"],"worker_preference":["backend-dev"],
  "acceptanceCriteria":["C"]},
 {"id":"S4","title":"four","priority":9,"passes":false,"dependsOn":[],"worker_preference":["gated-dev"],
  "acceptanceCriteria":["D"]},
 {"id":"S5","title":"five","priority":10,"passes":false,"dependsOn":[],"worker_preference":["checkpoint-dev"],
  "acceptanceCriteria":["E"]}
]}
EOF

# handoff <story> <phase> <worker> <status> <ac_evidence-json> -> path
handoff() {
  f="$T/h-$1-$2-$RANDOM.json"
  printf '{"schema":"hq-phase-handoff/v1","story_id":"%s","phase":"%s","worker_id":"%s","status":"%s","summary":"s","files_changed":[],"commits":[],"back_pressure":{"tests":"pass","lint":"skip","typecheck":"skip","build":"skip"},"context_for_next":"c","ac_evidence":%s}' \
    "$1" "$2" "$3" "$4" "$5" > "$f"
  echo "$f"
}
S="$T/state"
run() { "$PC" "$@" --state "$S" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }
pyget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

# A failed loop handoff keeps its actual validation error in both the owner note
# and the driver's senior-facing exit reason.
BS="$T/failure-reason"
mkdir -p "$BS/handoffs"
"$PC" classify --prd "$T/prd.json" --state "$BS" --story S1 >/dev/null
jq '.state = "in_flight" | .started = true' "$BS/stories/S1.json" >"$T/failed.tmp" && mv "$T/failed.tmp" "$BS/stories/S1.json"
cat >"$BS/handoffs/S1-backend.json" <<'EOF'
{"schema":"hq-phase-handoff/v1","story_id":"S1","phase":"backend","worker_id":"backend-dev","status":"failed","summary":"Phase execution failed.","files_changed":[],"commits":[],"back_pressure":{"tests":"skip","lint":"skip","typecheck":"skip","build":"skip"},"context_for_next":"handoff status must be passed, failed, or blocked","ac_evidence":[]}
EOF
set +e
PIPELINE_DRIVER_CONDUCTOR="$PC" PC_HQ="$T/bin/hq" PC_WORKERS_ROOT="$T/workers" \
  "$HERE/../pipeline-driver.sh" --prd "$T/prd.json" --state "$BS" --interval 0.1 --max-phase-fails 1 >"$T/failure-driver.out" 2>&1
driver_rc=$?
set +e
check "failcap owner note preserves the loop's exact failure reason" 'grep -q "handoff status must be passed, failed, or blocked" "$BS/decisions/S1-blocked-backend.md"'
check "senior-facing driver exit includes the loop's exact failure reason" '[ "$driver_rc" = 21 ] && grep -q "reason: handoff status must be passed, failed, or blocked" "$BS/driver/exit"'

# The loop prompt renders constraints, so the conductor must put the complete
# handoff contract there and the recheck must require AC evidence.
AC_PRD="$T/ac-prd.json"; AS="$T/ac-state"; AC_LANE=lane-backend-dev-ac
cat >"$AC_PRD" <<'EOF'
{"name":"ac-contract","userStories":[{"id":"AC1","title":"evidence contract","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["works"]}]}
EOF
printf '%s\n' "$AC_LANE" >"$T/lanes.txt"
printf '"company":{"slug":"indigo"},"project_id":"ac-contract","worker":"backend-dev"' >"$T/owner.$AC_LANE"
"$PC" classify --prd "$AC_PRD" --state "$AS" --story AC1 >/dev/null
mkdir -p "$AS"
printf '{"backend-dev":"%s"}\n' "$AC_LANE" >"$AS/lanes.json"
"$PC" route --prd "$AC_PRD" --state "$AS" --story AC1 >"$T/ac-route.out"
check "phase envelope constraints specify the full handoff and ac_evidence contract once" 'jq -e ".constraints | any(contains(\"status exactly passed, failed, or blocked\")) and any(contains(\"back_pressure.tests, lint, typecheck, and build\")) and any(contains(\"one ac_evidence entry per acceptance criterion as {index, criterion, met, evidence}\")) and ([.[] | select(contains(\"ac_evidence\"))] | length == 1)" "$AS/envelopes/AC1-backend.json" >/dev/null'
cat >"$T/ac-no-evidence.json" <<'EOF'
{"schema":"hq-phase-handoff/v1","story_id":"AC1","phase":"backend","worker_id":"backend-dev","status":"passed","summary":"done","files_changed":[],"commits":[],"back_pressure":{"tests":"skip","lint":"skip","typecheck":"skip","build":"skip"},"context_for_next":"ready"}
EOF
"$PC" accept --state "$AS" --story AC1 --handoff "$T/ac-no-evidence.json" >"$T/ac-accept.out"
"$PC" recheck --prd "$AC_PRD" --state "$AS" --story AC1 >"$T/ac-recheck-missing.out" 2>&1 || true
check "handoff without ac_evidence routes back to the acceptance criterion" 'grep -q "ROUTED_BACK AC1 backend unmet:0" "$T/ac-recheck-missing.out"'
"$PC" route --prd "$AC_PRD" --state "$AS" --story AC1 >"$T/ac-route-retry.out"
printf '{"schema":"hq-phase-handoff/v1","story_id":"AC1","phase":"backend","worker_id":"backend-dev","status":"passed","summary":"done","files_changed":[],"commits":[],"back_pressure":{"tests":"skip","lint":"skip","typecheck":"skip","build":"skip"},"context_for_next":"ready","ac_evidence":[{"index":0,"criterion":"works","met":true,"evidence":"assertion passed"}]}' >"$T/ac-with-evidence.json"
"$PC" accept --state "$AS" --story AC1 --handoff "$T/ac-with-evidence.json" >"$T/ac-accept-evidence.out"
"$PC" recheck --prd "$AC_PRD" --state "$AS" --story AC1 >"$T/ac-recheck-evidence.out"
check "handoff with matching ac_evidence passes recheck" 'grep -q "VERIFIED AC1" "$T/ac-recheck-evidence.out"'
: >"$T/lanes.txt"
rm -f "$T/owner.$AC_LANE"
: >"$T/pool.log"
: >"$T/hq.log"

# ---- e2e 3: dependsOn not passing -> not selected ----
run next --prd "$T/prd.json"
check "next orders by priority, S3 (dep S4 not passing) excluded" '[ "$(tr "\n" " " < "$T/out")" = "S2 S1 S4 S5 " ]'

# ---- e2e 1: two unblocked stories, free lanes -> both in flight in one tick ----
# S1 and S2 live in two repos, each with its own worktree, so both may be in flight.
mkdir -p "$T/repoA" "$T/repoB" "$T/wt2"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["userStories"]:
    if s["id"] == "S1": s["repoPath"] = sys.argv[3] + "/repoA"
    if s["id"] == "S2": s["repoPath"] = sys.argv[3] + "/repoB"
json.dump(d, open(sys.argv[2], "w"))' "$T/prd.json" "$T/prd-two.json" "$T"
PC_MAX_STORIES=2 run tick --prd "$T/prd-two.json" --worktree "$T/repoA=$T/wt" --worktree "$T/repoB=$T/wt2" --worktree "$T/wt"
check "tick exits 0" '[ "$(rc)" = 0 ]'
check "two stories enqueue into a shared worker lane" '[ "$(grep -c "^lanes enqueue " "$T/pool.log")" = 2 ] && [ "$(grep -c "^lanes create " "$T/pool.log")" = 1 ]'
check "each story routed to the worktree of its repo" \
  '[ "$(pyget "$S/stories/S2.json" "d[\"worktree\"]")" = "$T/wt2" ] && [ "$(pyget "$S/stories/S1.json" "d[\"repo\"]")" = "$T/repoA" ]'
check "both stories in_flight at once" 'grep -q "\"in_flight\"" "$S/stories/S1.json" && grep -q "\"in_flight\"" "$S/stories/S2.json"'
check "S3 not started" '[ ! -f "$S/stories/S3.json" ]'
check "envelopes queued through hq lanes enqueue --envelope" '[ -f "$T/queued/S1-backend.json" ] && [ -f "$T/queued/S2-backend.json" ] && grep -q "lanes enqueue .*--envelope" "$T/pool.log"'
check "envelope carries literal ACs and worktree" 'python3 -c "import json,sys;d=json.load(open(\"$T/queued/S1-backend.json\"));sys.exit(0 if d[\"acceptance_criteria\"]==[\"A one\",\"A two\"] and d[\"worktree\"]==\"$T/wt\" else 1)"'

# Different stories, different workers in the same tick: S1 moves to qa while S2 stays on backend.
: > "$T/pool.log"
run accept --story S1 --handoff "$(handoff S1 backend backend-dev passed '[]')"
check "accept advances to qa" 'grep -q "NEXT S1 qa" "$T/out"'
run route --prd "$T/prd.json" --story S1
check "qa routed with incoming handoff" '[ "$(rc)" = 0 ] && grep -q "\"incoming_handoff\": \"$S/handoffs/S1-backend.json\"" "$S/envelopes/S1-qa.json"'
check "qa-tester phase creates and uses its worker lane" 'grep -q -- "--worker qa-tester" "$T/pool.log" && grep -q "\"in_flight\"" "$S/stories/S2.json"'

# ---- invalid previous handoff refuses assign ----
: > "$T/pool.log"
python3 - "$S/stories/S2.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["current"]=1; d["state"]="queued"; json.dump(d,open(p,"w"))
PY
printf '{"schema":"hq-phase-handoff/v1","story_id":"S2"}' > "$S/handoffs/S2-backend.json"
run route --prd "$T/prd.json" --story S2
check "invalid previous handoff refuses route" '[ "$(rc)" = 1 ] && grep -q "previous handoff invalid" "$T/err" && [ ! -s "$T/pool.log" ]'
cp "$(handoff S2 backend backend-dev failed '[]')" "$S/handoffs/S2-backend.json"
run route --prd "$T/prd.json" --story S2
check "failed previous handoff refuses route" '[ "$(rc)" = 1 ] && grep -q "did not pass" "$T/err" && [ ! -s "$T/pool.log" ]'

# ---- pool busy -> retry ----
cp "$(handoff S2 backend backend-dev passed '[]')" "$S/handoffs/S2-backend.json"
 jq 'del(."qa-tester")' "$S/lanes.json" > "$T/lanes.tmp" && mv "$T/lanes.tmp" "$S/lanes.json"
echo 3 > "$T/pool.rc"
run route --prd "$T/prd.json" --story S2
check "lane admission refusal -> RETRY, exit 3, story stays queued" '[ "$(rc)" = 3 ] && grep -q "RETRY S2 qa lanes-admission_denied" "$T/out" && grep -q "\"queued\"" "$S/stories/S2.json"'
rm -f "$T/pool.rc"
run route --prd "$T/prd.json" --story S2
check "retry on next attempt routes" '[ "$(rc)" = 0 ]'

# ---- e2e 2: status passed but unmet AC -> not verified, routed back, then reported once ----
cp "$T/prd.json" "$T/prd.before"
run accept --story S1 --handoff "$(handoff S1 qa qa-tester passed '[{"index":0,"met":true,"evidence":"test x"},{"index":1,"met":false,"evidence":""}]')"
check "last phase -> RECHECK" 'grep -q "RECHECK S1" "$T/out"'
run recheck --prd "$T/prd.json" --story S1
check "unmet AC routes back (exit 1, ROUTED_BACK)" '[ "$(rc)" = 1 ] && grep -q "ROUTED_BACK S1 qa unmet:1" "$T/out"'
check "story not verified after unmet AC" 'grep -q "\"queued\"" "$S/stories/S1.json" && ! grep -q verified "$S/stories/S1.json"'
check "prd untouched (passes stays false)" 'cmp -s "$T/prd.json" "$T/prd.before"'
check "no report line after first fail" '! grep -q "S1" "$S/report.md" 2>/dev/null'
run route --prd "$T/prd.json" --story S1
check "rerouted phase gets fresh_call" '[ "$(rc)" = 0 ] && grep -q "\"fresh_call\": true" "$S/envelopes/S1-qa.json"'
run accept --story S1 --handoff "$(handoff S1 qa qa-tester passed '[{"index":0,"met":true,"evidence":"x"},{"index":1,"met":true,"evidence":"  "}]')"
run recheck --prd "$T/prd.json" --story S1
check "second fail -> FAILED, failed_report" '[ "$(rc)" = 1 ] && grep -q "FAILED S1" "$T/out" && grep -q failed_report "$S/stories/S1.json"'
run report story --story S1
check "failed story reported exactly once" '[ "$(grep -c "^- S1 " "$S/report.md")" = 1 ]'
check "prd still untouched" 'cmp -s "$T/prd.json" "$T/prd.before"'

# S2 passes the re-check with full evidence
run accept --story S2 --handoff "$(handoff S2 qa qa-tester passed '[{"index":0,"met":true,"evidence":"curl returns 200"}]')"
run recheck --prd "$T/prd.json" --story S2
check "full evidence -> VERIFIED" '[ "$(rc)" = 0 ] && grep -q "VERIFIED S2" "$T/out"'
check "prd untouched after verify" 'cmp -s "$T/prd.json" "$T/prd.before"'

# ---- e2e 4: approval_required -> decision item, no envelope ----
: > "$T/pool.log"
run classify --prd "$T/prd.json" --story S4 --worktree "$T/wt"
run route --prd "$T/prd.json" --story S4
check "approval_required holds: exit 10" '[ "$(rc)" = 10 ] && grep -q "HELD S4" "$T/out"'
check "decision item written" '[ -f "$S/decisions/S4-gated-dev.md" ] && grep -q "approval_required: true" "$S/decisions/S4-gated-dev.md"'
check "no envelope queued for held story" '[ ! -f "$S/envelopes/S4-gated-dev.json" ] && [ ! -f "$T/queued/S4-gated-dev.json" ] && [ ! -s "$T/pool.log" ]'
run classify --prd "$T/prd.json" --story S5 --worktree "$T/wt"
run route --prd "$T/prd.json" --story S5
check "human_checkpoints holds too" '[ "$(rc)" = 10 ] && grep -q "human_checkpoints: before_deploy" "$S/decisions/S5-checkpoint-dev.md" && [ ! -s "$T/pool.log" ]'
run release --story S4
run route --prd "$T/prd.json" --story S4
check "release then route queues the envelope" '[ "$(rc)" = 0 ] && grep -q "status: approved" "$S/decisions/S4-gated-dev.md" && [ -f "$T/queued/S4-gated-dev.json" ]'

# ---- gate cadence and failure ----
G="$T/gstate"
for i in 1 2; do "$PC" gate tick --state "$G" > "$T/out"; done
check "no RUN_GATE before cadence" '! grep -q RUN_GATE "$T/out"'
"$PC" gate tick --state "$G" > "$T/out"
check "RUN_GATE on 3rd completed story (default cadence)" 'grep -q RUN_GATE "$T/out"'
"$PC" gate result fail --state "$G" --note "tests red" >/dev/null
"$PC" next --prd "$T/prd.json" --state "$G" > "$T/out"
check "gate failure: next prints nothing" '[ ! -s "$T/out" ]'
"$PC" gate result pass --state "$G" >/dev/null
"$PC" next --prd "$T/prd.json" --state "$G" > "$T/out"
check "gate pass: next resumes" '[ -s "$T/out" ]'

# ---- worktree --shared ----
R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q -b main && git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
W="$T/wstate"
"$PC" classify --prd "$T/prd.json" --state "$W" --story S2 >/dev/null
wt="$("$PC" worktree --state "$W" --story S2 --repo "$R" --shared --story-branches --prd "$T/prd.json" 2>/dev/null)"
check "--story-branches: a per-story worktree" '[ -d "$wt" ] && [ "$wt" != "$R" ] && git -C "$wt" rev-parse --abbrev-ref HEAD | grep -q "pipeline/S2"'
"$PC" route --prd "$T/prd.json" --state "$W" --story S2 >/dev/null
check "envelope names the worktree" 'grep -q "\"worktree\": \"$wt\"" "$W/envelopes/S2-backend.json"'
mkdir -p "$T/hq/inner"; git -C "$T/hq/inner" init -q
"$PC" worktree --state "$W" --story S2 --repo "$T/hq/inner" --shared --prd "$T/prd.json" >/dev/null 2>"$T/err"; irc=$?
check "repo inside HQ root refused" '[ $irc -ne 0 ] && grep -q "inside the HQ root" "$T/err"'
check "worktree code uses git -C only" '! grep -nE "(^|[;&|[:space:]])git [a-z]" "$PC" | grep -v "git -C" | grep -v "^[0-9]*:#" | grep -q .'

# ---- report: one line per story, none per phase; final summary ----
run report story --story S2
run report story --story S2
run report final
check "one line per finished story" '[ "$(grep -c "^- S2 " "$S/report.md")" = 1 ] && [ "$(grep -c "^- " "$S/report.md")" = 2 ]'
check "no per-phase lines" '! grep -qiE "backend|qa" "$S/report.md"'
check "final summary present once" '[ "$(grep -c "^FINAL:" "$S/report.md")" = 1 ] && grep -q "verified 1, failed 1" "$S/report.md"'
run report story --story S5
check "unfinished story cannot be reported" '[ "$(rc)" = 1 ]'

# ---- review regressions ----
( "$PC" next --state & p=$!; i=0; while kill -0 $p 2>/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 $p 2>/dev/null; then kill $p; exit 1; fi; wait $p; [ $? = 2 ] ) 2>/dev/null
check "flag missing its value exits 2 instead of looping" '[ $? = 0 ]'
cp "$S/stories/S2.json" "$T/s2.before"
run accept --story S2 --handoff "$(handoff S2 qa qa-tester passed '[{"index":0,"met":true,"evidence":"x"}]')"
check "handoff for a verified story is refused, state unchanged" '[ "$(rc)" = 1 ] && grep -q "not in_flight" "$T/err" && cmp -s "$S/stories/S2.json" "$T/s2.before"'
run accept --story S1 --handoff "$(handoff S1 qa qa-tester passed '[{"index":0,"met":true,"evidence":"x"},{"index":1,"met":true,"evidence":"y"}]')"
check "handoff cannot revive a failed_report story" '[ "$(rc)" = 1 ] && grep -q failed_report "$S/stories/S1.json"'
run classify --prd "$T/prd.json" --story ../escape
check "path-traversal story id refused" '[ "$(rc)" = 2 ] && [ ! -e "$T/escape.json" ]'
run next --prd "$T/prd.json" --limit x
check "non-integer --limit exits 2" '[ "$(rc)" = 2 ]'

# ==== blocked handoffs and owner resolutions ====
cat > "$T/prd2.json" <<'EOF'
{"name":"demo2","userStories":[
 {"id":"P1","title":"needs people","priority":1,"passes":false,"dependsOn":[],"worker_preference":["backend-dev"],
  "acceptanceCriteria":["P1 zero","P1 one","P1 two"]},
 {"id":"P2","title":"after P1","priority":2,"passes":false,"dependsOn":["P1"],"worker_preference":["backend-dev"],
  "acceptanceCriteria":["P2 zero"]},
 {"id":"P3","title":"after P2","priority":3,"passes":false,"dependsOn":["P2"],"worker_preference":["backend-dev"],
  "acceptanceCriteria":["P3 zero"]},
 {"id":"P4","title":"independent","priority":4,"passes":false,"dependsOn":[],"worker_preference":["backend-dev"],
  "acceptanceCriteria":["P4 zero"]}
]}
EOF
cp "$T/prd2.json" "$T/prd2.before"
S="$T/bstate"
blocked_handoff() { # blocked_handoff <story> -> path; worker text in summary and notes
  f="$(handoff "$1" backend backend-dev blocked '[{"index":0,"met":true,"evidence":"part zero done"}]')"
  python3 - "$f" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p))
d["summary"]="Two criteria need a person to run timed trials."; d["notes"]="Rerunning will not change this."
json.dump(d,open(p,"w"))
PY
  echo "$f"
}
: > "$T/pool.log"
run classify --prd "$T/prd2.json" --story P1 --worktree "$T/wt"
run route --prd "$T/prd2.json" --story P1
run accept --story P1 --handoff "$(blocked_handoff P1)"
check "blocked handoff: accept exits 10 with PHASE_BLOCKED" '[ "$(rc)" = 10 ] && grep -q "^PHASE_BLOCKED P1 backend " "$T/out"'
check "blocked handoff: story held as blocked_needs_owner, not re-queued" '[ "$(pyget "$S/stories/P1.json" "d[\"state\"]")" = blocked_needs_owner ]'
D="$S/decisions/P1-blocked-backend.md"
check "blocked handoff: one decision item with story, phase, lane and the worker's text" \
  '[ -f "$D" ] && grep -q "story: P1" "$D" && grep -q "phase: backend" "$D" && grep -q "lane: backend-dev" "$D" && grep -q "timed trials" "$D" && grep -q "Rerunning will not change this" "$D" && grep -q "status: pending" "$D" && [ "$(ls "$S/decisions" | wc -l | tr -d " ")" = 1 ]'
: > "$T/pool.log"
run route --prd "$T/prd2.json" --story P1
check "blocked story is not routed again" '[ "$(rc)" = 1 ] && [ ! -s "$T/pool.log" ]'
run tick --prd "$T/prd2.json" --worktree "$T/wt"
check "tick routes the independent story, not the blocked one or its dependent" \
  'grep -q -- "lanes enqueue" "$T/pool.log" && grep -q "ROUTED P4 " "$T/out" && ! grep -q "P1\|P2" "$T/out" && [ ! -f "$S/stories/P2.json" ]'

# refusals and usage
run resolve --story P1 --as accepted-partial
check "accepted-partial without --note exits 2" '[ "$(rc)" = 2 ] && [ "$(pyget "$S/stories/P1.json" "d[\"state\"]")" = blocked_needs_owner ]'
run resolve --story P1 --as maybe --note x
check "resolve --as with an unknown value exits 2" '[ "$(rc)" = 2 ]'
run resolve --story P4 --as accepted-partial --note x
check "accepted-partial refuses a story that is not blocked" '[ "$(rc)" = 1 ] && grep -q "is in_flight" "$T/err" && [ "$(pyget "$S/stories/P4.json" "d[\"state\"]")" = in_flight ]'
run resolve --story P4 --as retry
check "retry refuses a story that is not blocked" '[ "$(rc)" = 1 ] && grep -q "blocked_needs_owner" "$T/err"'
run resolve --story P9 --as retry
check "resolve refuses a story with no state" '[ "$(rc)" = 1 ]'

# retry: fresh call with the owner's answer, idempotent
run resolve --story P1 --as retry --note "Use the sample numbers in the appendix."
check "retry: queued again, blocked handoff archived, decision resolved" \
  '[ "$(rc)" = 0 ] && grep -q "RESOLVED P1 retry backend" "$T/out" && [ "$(pyget "$S/stories/P1.json" "d[\"state\"]")" = queued ] && [ -f "$S/handoffs/P1-backend.failed.1.json" ] && [ ! -f "$S/handoffs/P1-backend.json" ] && grep -q "status: resolved: retry" "$D"'
run resolve --story P1 --as retry --note "Use the sample numbers in the appendix."
check "retry is idempotent" '[ "$(rc)" = 0 ] && grep -q "ALREADY retry P1" "$T/out" && [ ! -f "$S/handoffs/P1-backend.failed.2.json" ]'
: > "$T/pool.log"
run route --prd "$T/prd2.json" --story P1
check "retry routes a fresh call carrying the owner's note" \
  '[ "$(rc)" = 0 ] && [ "$(pyget "$S/envelopes/P1-backend.json" "d[\"fresh_call\"]")" = True ] && grep -q "sample numbers in the appendix" "$S/envelopes/P1-backend.json" && [ -s "$T/pool.log" ]'
run resolve --story P1 --as retry
check "retry while the phase runs is still idempotent" '[ "$(rc)" = 0 ] && grep -q ALREADY "$T/out"'
run accept --story P1 --handoff "$(blocked_handoff P1)"
check "blocked again: held again, attempts counted" '[ "$(rc)" = 10 ] && [ "$(pyget "$S/stories/P1.json" "d[\"blocked\"][\"attempts\"]")" = 2 ] && grep -q "status: pending" "$D"'

# accepted-partial: terminal, satisfies dependsOn, passes never set
run resolve --story P1 --as accepted-partial --note "Owner accepts the draft; trials happen later."
check "accepted-partial: distinct terminal state with note and unmet ACs stored" \
  '[ "$(rc)" = 0 ] && grep -q "RESOLVED P1 accepted-partial unmet:1,2 passes-not-set" "$T/out" && [ "$(pyget "$S/stories/P1.json" "d[\"state\"]")" = accepted_partial ] && [ "$(pyget "$S/stories/P1.json" "d[\"resolution\"][\"unmet\"]")" = "[1, 2]" ] && pyget "$S/stories/P1.json" "d[\"resolution\"][\"note\"]" | grep -q "trials happen later"'
check "accepted-partial: report line says partial and passes not set" \
  'grep -q "^- P1 accepted by the owner as a partial draft, not verified; passes is not set: needs people (unmet AC: 1,2; owner note: Owner accepts the draft; trials happen later.)" "$S/report.md"'
check "accepted-partial: prd untouched" 'cmp -s "$T/prd2.json" "$T/prd2.before"'
run resolve --story P1 --as accepted-partial --note "again"
check "accepted-partial is idempotent" '[ "$(rc)" = 0 ] && grep -q "ALREADY accepted-partial P1" "$T/out" && [ "$(grep -c "^- P1 " "$S/report.md")" = 1 ] && pyget "$S/stories/P1.json" "d[\"resolution\"][\"note\"]" | grep -q "trials happen later"'
run resolve --story P1 --as retry
check "retry refuses an accepted-partial story" '[ "$(rc)" = 1 ]'
run next --prd "$T/prd2.json"
check "accepted-partial satisfies dependsOn: P2 is eligible" 'grep -qx P2 "$T/out"'
run report final
check "final summary counts the partial story and says passes is not set" \
  'grep -q "^FINAL: verified 0, failed 0, partial 1, .*partial drafts, passes not set: P1 (unmet AC 1,2)" "$S/report.md"'

# park / unpark
S="$T/pstate"
run park --story P2 --note "waiting on a vendor" --prd "$T/prd2.json"
check "park: not-started story parked, transitive dependent held as parked_dependency" \
  '[ "$(rc)" = 0 ] && grep -q "PARKED P2" "$T/out" && [ "$(pyget "$S/stories/P2.json" "d[\"state\"]")" = parked ] && [ "$(pyget "$S/stories/P3.json" "d[\"state\"]")" = parked_dependency ] && [ "$(pyget "$S/stories/P3.json" "\",\".join(d[\"parked_by\"])")" = P2 ]'
run park --story P2 --prd "$T/prd2.json"
check "park is idempotent" '[ "$(rc)" = 0 ] && grep -q "ALREADY parked P2" "$T/out" && pyget "$S/stories/P2.json" "d[\"parked\"][\"note\"]" | grep -q vendor'
run next --prd "$T/prd2.json"
check "parked and parked_dependency stories are not eligible; others are" '[ "$(tr "\n" " " < "$T/out")" = "P1 P4 " ]'
run classify --prd "$T/prd2.json" --story P4 --worktree "$T/wt"
run route --prd "$T/prd2.json" --story P4
run park --story P4
check "park refuses an in-flight story" '[ "$(rc)" = 1 ] && grep -q "is in_flight" "$T/err" && [ "$(pyget "$S/stories/P4.json" "d[\"state\"]")" = in_flight ]'
run park --story P3 --prd "$T/prd2.json"
check "park refuses a parked_dependency story" '[ "$(rc)" = 1 ]'
run report final
check "final summary lists parked stories, why, and what they hold" 'grep -q "parked 1, .*parked P2 (waiting on a vendor; holds P3)" "$S/report.md"'
run unpark --story P4
check "unpark refuses a story that is not parked" '[ "$(rc)" = 1 ] && grep -q "not parked\|applies only to a parked" "$T/err"'
run unpark --story P2 --prd "$T/prd2.json"
check "unpark reverses park and releases the dependent" \
  '[ "$(rc)" = 0 ] && grep -q "UNPARKED P2 not-started" "$T/out" && [ ! -f "$S/stories/P2.json" ] && [ ! -f "$S/stories/P3.json" ]'
run unpark --story P2 --prd "$T/prd2.json"
check "unpark is idempotent" '[ "$(rc)" = 0 ] && grep -q "ALREADY unparked P2" "$T/out"'
# park a blocked story: unpark restores the hold
run classify --prd "$T/prd2.json" --story P1 --worktree "$T/wt"
run route --prd "$T/prd2.json" --story P1
run accept --story P1 --handoff "$(blocked_handoff P1)"
run park --story P1 --note "later" --prd "$T/prd2.json"
check "park a blocked story holds P2 and P3 as parked_dependency" \
  '[ "$(pyget "$S/stories/P2.json" "d[\"state\"]")" = parked_dependency ] && [ "$(pyget "$S/stories/P3.json" "\",\".join(d[\"parked_by\"])")" = P1 ] && grep -q "status: parked" "$S/decisions/P1-blocked-backend.md"'
run unpark --story P1
check "unpark restores blocked_needs_owner; tick releases dependents" \
  '[ "$(pyget "$S/stories/P1.json" "d[\"state\"]")" = blocked_needs_owner ] && grep -q "status: pending" "$S/decisions/P1-blocked-backend.md"'
run tick --prd "$T/prd2.json" --worktree "$T/wt"
check "tick releases parked_dependency stubs after unpark" '[ ! -f "$S/stories/P2.json" ] && [ ! -f "$S/stories/P3.json" ] && grep -q "RELEASED_DEPENDENCY P2" "$T/out"'

# ---- previous-version state dir: a queued story with two archived blocked handoffs ----
S="$T/legacy"; mkdir -p "$S/stories" "$S/handoffs" "$S/envelopes" "$S/decisions"
cat > "$S/stories/P1.json" <<'EOF'
{"id":"P1","title":"needs people","phases":[{"phase":"architect","worker":"architect"}],"current":0,"state":"queued",
 "reroutes":0,"worktree":"/tmp/wt","started":true}
EOF
cat > "$S/envelopes/P1-architect.json" <<'EOF'
{"schema":"hq-phase-envelope/v1","story_id":"P1","phase":"architect","worker_id":"architect","worktree":"/tmp/wt",
 "incoming_handoff":null,"acceptance_criteria":["P1 zero","P1 one","P1 two"],"deadline":"2030-01-01T00:00:00Z",
 "fresh_call":false,"result_path":"/tmp/none.json"}
EOF
for n in 1 2; do
  f="$(handoff P1 architect architect blocked '[{"index":0,"met":true,"evidence":"part zero","criterion":"P1 zero"},{"index":2,"met":true,"evidence":"part two","criterion":"P1 two"},{"index":1,"met":false,"evidence":"needs trials","criterion":"P1 one"}]')"
  mv "$f" "$S/handoffs/P1-architect.failed.$n.json"
done
printf -- '- P0 verified: earlier\n' > "$S/report.md"
cp -R "$S" "$T/legacy.before"
run resolve --story P1 --as accepted-partial --note "Owner accepts the draft."
check "legacy state: accepted-partial works without hand edits or --prd" \
  '[ "$(rc)" = 0 ] && grep -q "RESOLVED P1 accepted-partial unmet:1 passes-not-set" "$T/out" && [ "$(pyget "$S/stories/P1.json" "d[\"state\"]")" = accepted_partial ]'
check "legacy state: decision item written from the archived handoff and marked resolved" \
  'grep -q "lane: architect" "$S/decisions/P1-blocked-architect.md" && grep -q "attempts so far: 2" "$S/decisions/P1-blocked-architect.md" && grep -q "status: resolved: accepted-partial" "$S/decisions/P1-blocked-architect.md"'
check "legacy state: archived handoffs left in place" 'cmp -s "$S/handoffs/P1-architect.failed.2.json" "$T/legacy.before/handoffs/P1-architect.failed.2.json"'
rm -rf "$S"; cp -R "$T/legacy.before" "$S"
: > "$T/pool.log"
cat > "$T/prd3.json" <<'EOF'
{"name":"legacy","userStories":[
 {"id":"P1","title":"needs people","priority":1,"passes":false,"dependsOn":[],"worker_preference":["architect"],
  "acceptanceCriteria":["P1 zero","P1 one","P1 two"]}]}
EOF
run tick --prd "$T/prd3.json"
check "legacy state: tick does not re-route the blocked story" '[ ! -s "$T/pool.log" ] && [ "$(pyget "$S/stories/P1.json" "d[\"state\"]")" = blocked_needs_owner ]'
S="$T/state"

# ---- lane down: enqueue reports loop_not_running ----
S="$T/state-lanedown"
cat > "$T/prd-ld.json" <<'EOF'
{"name":"ld","userStories":[
 {"id":"L1","title":"one","priority":1,"passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["L one"]},
 {"id":"L2","title":"two","priority":2,"passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["L two"]}]}
EOF
for ans in resume spawn; do
  rm -rf "$S"; : > "$T/pool.log"; rm -f "$T/queued/L1-backend.json"
  echo "$ans" > "$T/pool.answer"
  run classify --prd "$T/prd-ld.json" --story L1 --worktree "$T/wt"
  run route --prd "$T/prd-ld.json" --story L1
  check "lane down ($ans): route exits 11 and names the worker lane" \
    '[ "$(rc)" = 11 ] && grep -q "^LANE_DOWN L1 backend backend-dev lanes-loop_not_running" "$T/out"'
  check "lane down ($ans): story stays queued and the worker mapping is dropped" \
    '[ "$(pyget "$S/stories/L1.json" "d[\"state\"]")" = queued ] && [ ! -f "$T/queued/L1-backend.json" ] && [ "$(pyget "$S/lanes.json" "d.get(\"backend-dev\")")" = None ]'
done
rm -rf "$S"; : > "$T/pool.log"
PC_MAX_STORIES=2 run tick --prd "$T/prd-ld.json" --worktree "$T/wt"
check "lane down: tick prints LANE_DOWN once and stops routing" \
  '[ "$(rc)" = 0 ] && [ "$(grep -c "^LANE_DOWN" "$T/out")" = 1 ] && [ "$(grep -c "^lanes enqueue " "$T/pool.log")" = 1 ] && ! grep -q ERROR "$T/out"'
rm -f "$T/pool.answer"
run tick --prd "$T/prd-ld.json" --worktree "$T/wt"
check "lane back: the next tick routes the queued story normally" \
  'grep -q "^ROUTED L1 backend backend-dev" "$T/out" && [ "$(pyget "$S/stories/L1.json" "d[\"state\"]")" = in_flight ]'
lane="$(pyget "$S/lanes.json" 'd["backend-dev"]')"
printf '"company":{"slug":"another-company"},"project_id":"ld","worker":"backend-dev"' > "$T/owner.$lane"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["state"]="queued"; json.dump(d,open(p,"w"))' "$S/stories/L1.json"
before="$(grep -c '^lanes enqueue ' "$T/pool.log")"
run route --prd "$T/prd-ld.json" --story L1
check "mapped lane owned by another company is refused before enqueue" \
  '[ "$(rc)" != 0 ] && grep -q "different company, project, or worker" "$T/err" && [ "$(grep -c "^lanes enqueue " "$T/pool.log")" = "$before" ]'

# ---- failcap: a phase that failed too often is held for the owner ----
S="$T/state-failcap"; rm -rf "$S"; : > "$T/pool.log"
cat > "$T/prd-fc.json" <<'EOF'
{"name":"fc","userStories":[
 {"id":"F1","title":"wrong lane","priority":1,"passes":false,"dependsOn":[],"worker_preference":["qa-tester","backend-dev"],"acceptanceCriteria":["F one"]}]}
EOF
run classify --prd "$T/prd-fc.json" --story F1 --worktree "$T/wt"
run route --prd "$T/prd-fc.json" --story F1
fh() { # fh <summary> -> a failed qa handoff of F1 on stdout
  printf '{"schema":"hq-phase-handoff/v1","story_id":"F1","phase":"qa","worker_id":"qa-tester","status":"failed","summary":"%s","files_changed":[],"commits":[],"back_pressure":{"tests":"fail","lint":"skip","typecheck":"skip","build":"skip"},"context_for_next":"","ac_evidence":[]}\n' "$1"
}
fh "no infra to test yet (first try)" > "$S/handoffs/F1-qa.failed.1.json"
fh "still no infra to test (second try)" > "$S/handoffs/F1-qa.json"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["state"]="queued"; json.dump(d,open(p,"w"))' "$S/stories/F1.json"
run failcap --story F1
DF="$S/decisions/F1-blocked-qa.md"
check "failcap: story held as blocked_needs_owner, exit 10" \
  '[ "$(rc)" = 10 ] && grep -q "^PHASE_FAILCAP F1 qa $DF" "$T/out" && [ "$(pyget "$S/stories/F1.json" "d[\"state\"]")" = blocked_needs_owner ]'
check "failcap: decision item names story, phase, lane and both failure texts" \
  'grep -q "story: F1" "$DF" && grep -q "phase: qa" "$DF" && grep -q "lane: qa-tester" "$DF" && grep -q "first try" "$DF" && grep -q "second try" "$DF" && grep -q "failed attempts: 2" "$DF"'
run failcap --story F1
check "failcap: idempotent" '[ "$(rc)" = 10 ] && grep -q "^ALREADY blocked F1" "$T/out"'
: > "$T/pool.log"
run tick --prd "$T/prd-fc.json"
check "failcap: tick does not re-route the held story" '! grep -q "^assign" "$T/pool.log"'

# ---- retry re-reads the phases from the prd and starts the count over ----
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["userStories"][0]["worker_preference"]=["backend-dev","qa-tester"]; json.dump(d,open(p,"w"))' "$T/prd-fc.json"
run resolve --story F1 --as retry --prd "$T/prd-fc.json" --note "backend first, then qa"
check "retry: re-classified from the prd, resumes at the new first phase" \
  '[ "$(rc)" = 0 ] && grep -q "RESOLVED F1 retry qa phases:backend,qa next:backend" "$T/out" && [ "$(pyget "$S/stories/F1.json" "\",\".join(p[\"worker\"] for p in d[\"phases\"])")" = "backend-dev,qa-tester" ] && [ "$(pyget "$S/stories/F1.json" "d[\"current\"]")" = 0 ]'
check "retry: failed attempts acknowledged, so the count starts over" \
  '[ "$(pyget "$S/stories/F1.json" "d[\"fail_ack\"][\"qa\"]")" = 2 ] && [ -f "$S/handoffs/F1-qa.failed.2.json" ] && [ ! -f "$S/handoffs/F1-qa.json" ] && grep -q "status: resolved: retry" "$DF"'
: > "$T/pool.log"
run tick --prd "$T/prd-fc.json"
check "retry: tick routes the corrected first phase to its lane" 'grep -q "^ROUTED F1 backend backend-dev" "$T/out"'
S="$T/state"

# ---- reopen: send a verified or accepted_partial story back ----
S="$T/state-ro"; mkdir -p "$S/stories" "$S/handoffs"
cat > "$T/prd-ro.json" <<'EOF'
{"name":"demo","userStories":[
 {"id":"R1","title":"store change","passes":true,"dependsOn":[],"worker_preference":["backend-dev","qa-tester"],
  "files":["libs/demo/src/store.ts"],"acceptanceCriteria":["R1 AC"]},
 {"id":"R2","title":"uses R1","passes":false,"dependsOn":["R1"],"worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["R2 AC"]},
 {"id":"R3","title":"uses R2","passes":false,"dependsOn":["R2"],"worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["R3 AC"]},
 {"id":"R4","title":"partial","passes":false,"dependsOn":[],"worker_preference":["backend-dev","qa-tester"],
  "files":["apps/demo/src/page.ts"],"acceptanceCriteria":["R4 AC zero","R4 AC one"]},
 {"id":"R5","title":"still queued","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["R5 AC"]}
]}
EOF
mkst() { # mkst <id> <state> <current> [extra json]
  printf '{"id":"%s","title":"t","phases":[{"phase":"backend","worker":"backend-dev"},{"phase":"qa","worker":"qa-tester"}],"current":%s,"state":"%s","reroutes":0,"worktree":"%s","started":true%s}\n' \
    "$1" "$3" "$2" "$T/wt" "${4:-}" > "$S/stories/$1.json"
}
mkst R1 verified 1; mkst R2 verified 1; mkst R3 verified 1; mkst R4 accepted_partial 1 ',"resolution":{"as":"accepted-partial","note":"draft","unmet":[1]}'
printf '{"id":"R5","title":"t","phases":[{"phase":"backend","worker":"backend-dev"}],"current":0,"state":"queued","reroutes":0,"worktree":"%s"}\n' "$T/wt" > "$S/stories/R5.json"
for sid in R1 R2 R3 R4; do
  cp "$(handoff "$sid" backend backend-dev passed '[]')" "$S/handoffs/$sid-backend.json"
  cp "$(handoff "$sid" qa qa-tester passed '[{"index":0,"met":true,"evidence":"e"}]')" "$S/handoffs/$sid-qa.json"
done
cp "$(handoff R4 qa qa-tester blocked '[{"index":0,"met":true,"evidence":"e"}]')" "$S/handoffs/R4-qa.json"
printf '{"prd":"%s"}\n' "$T/prd-ro.json" > "$S/run.json"
printf -- '- R1 verified: t\n- R2 verified: t\n' > "$S/report.md"

run reopen --story R1
check "reopen: --note is required (exit 2)" '[ "$(rc)" = 2 ] && grep -q "needs --note" "$T/err"'
run reopen --story R5 --note "why"
check "reopen: refuses a queued story that was never reopened" \
  '[ "$(rc)" = 1 ] && grep -q "R5 is queued; reopen applies only to a verified or accepted_partial story" "$T/err"'
run reopen --story R1 --note "guard test fails" --from-phase nope
check "reopen: an unknown --from-phase is refused and changes nothing" \
  '[ "$(rc)" = 2 ] && [ "$(pyget "$S/stories/R1.json" "d[\"state\"]")" = verified ] && [ -f "$S/handoffs/R1-qa.json" ]'
run reopen --story R1 --note "guard test fails"
check "reopen verified (default phase): queued at the first implementing phase" \
  '[ "$(rc)" = 0 ] && grep -q "^REOPENED R1 from:verified phase:backend archived:2 verified-dependents:R2,R3$" "$T/out" && [ "$(pyget "$S/stories/R1.json" "d[\"state\"]")" = queued ] && [ "$(pyget "$S/stories/R1.json" "d[\"current\"]")" = 0 ]'
check "reopen: earlier handoffs kept on disk as history" \
  '[ -f "$S/handoffs/R1-backend.reopened.1.json" ] && [ -f "$S/handoffs/R1-qa.reopened.1.json" ] && [ ! -f "$S/handoffs/R1-backend.json" ] && [ ! -f "$S/handoffs/R1-qa.json" ]'
check "reopen: passes:true cleared in the prd and said so" \
  'grep -q "^PASSES_CLEARED R1 in $T/prd-ro.json" "$T/out" && [ "$(pyget "$T/prd-ro.json" "d[\"userStories\"][0][\"passes\"]")" = False ]'
check "reopen: verified dependents are not reopened" \
  '[ "$(pyget "$S/stories/R2.json" "d[\"state\"]")" = verified ] && [ "$(pyget "$S/stories/R3.json" "d[\"state\"]")" = verified ]'
check "reopen: attempt count reset and the old report line dropped" \
  '[ "$(pyget "$S/stories/R1.json" "d[\"reroutes\"]")" = 0 ] && ! grep -q "^- R1 " "$S/report.md" && grep -q "^- R2 " "$S/report.md"'
run reopen --story R1 --note "guard test fails"
check "reopen: idempotent on a story already queued by a reopen" \
  '[ "$(rc)" = 0 ] && grep -q "^ALREADY reopened R1 at backend" "$T/out" && [ ! -f "$S/handoffs/R1-backend.reopened.2.json" ]'
run reopen --story R4 --note "finish the second criterion" --from-phase qa
check "reopen accepted_partial (explicit --from-phase): queued at qa, backend handoff kept" \
  '[ "$(rc)" = 0 ] && grep -q "^REOPENED R4 from:accepted_partial phase:qa archived:1" "$T/out" && [ "$(pyget "$S/stories/R4.json" "d[\"current\"]")" = 1 ] && [ -f "$S/handoffs/R4-backend.json" ] && [ -f "$S/handoffs/R4-qa.reopened.1.json" ] && ! grep -q PASSES_CLEARED "$T/out"'
: > "$T/pool.log"; rm -f "$T/queued/R1-backend.json"
run tick --prd "$T/prd-ro.json"
check "reopen: the next tick routes the reopened story first" \
  '[ "$(grep -m1 "^ROUTED" "$T/out" | cut -d" " -f2)" = R1 ] && grep -q "^ROUTED R4 qa qa-tester" "$T/out"'
ER="$T/queued/R1-backend.json"
check "reopen: the note reaches the worker in the next envelope" \
  '[ "$(pyget "$ER" "d[\"reopen_note\"]")" = "guard test fails" ] && pyget "$ER" "d[\"constraints\"]" | grep -q "has been reopened at this phase. Why: guard test fails" && [ "$(pyget "$ER" "d[\"fresh_call\"]")" = True ]'
check "back-pressure: a store/schema story's envelope asks for schema-contract tests, if present" \
  'pyget "$ER" "d[\"constraints\"]" | grep -q "schema-contract tests.*if present"'
check "back-pressure: no hint for a story without store or schema files" \
  '! grep -q "schema-contract" "$T/queued/R4-qa.json"'
check "reopen: the qa envelope of R4 receives the backend handoff as incoming context" \
  '[ "$(pyget "$T/queued/R4-qa.json" "d[\"incoming_handoff\"]")" = "$S/handoffs/R4-backend.json" ] && grep -q "finish the second criterion" "$T/queued/R4-qa.json"'
run report final
check "reopen: final summary lists the dependents verified before the reopen" \
  'grep -q "verified before R1 was reopened: R2, R3" "$T/out" && grep -q "reopened R1 at backend (guard test fails)" "$T/out"'

# ---- gate result fail --story: the conductor reopens the story itself ----
S="$T/state-gf"; mkdir -p "$S/stories" "$S/handoffs"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["userStories"]=[dict(s,id=s["id"].replace("R","G"),dependsOn=[x.replace("R","G") for x in s["dependsOn"]]) for s in d["userStories"][:2]]; json.dump(d,open(sys.argv[2],"w"))' "$T/prd-ro.json" "$T/prd-gf.json"
mkst G1 verified 1; mkst G2 verified 1
for sid in G1 G2; do
  cp "$(handoff "$sid" backend backend-dev passed '[]')" "$S/handoffs/$sid-backend.json"
  cp "$(handoff "$sid" qa qa-tester passed '[{"index":0,"met":true,"evidence":"e"}]')" "$S/handoffs/$sid-qa.json"
done
printf '{"completed":3,"state":"due","every":3,"note":""}\n' > "$S/gate.json"
run gate result fail --story G1 --note "guard test flags G1" --prd "$T/prd-gf.json"
check "gate fail --story: reopens the story and records the gate as reopened" \
  '[ "$(rc)" = 0 ] && grep -q "^REOPENED G1 from:verified phase:backend archived:2 verified-dependents:G2" "$T/out" && grep -q "^GATE reopened G1" "$T/out" && [ "$(pyget "$S/gate.json" "d[\"state\"]")" = reopened ] && [ "$(pyget "$S/gate.json" "\",\".join(d[\"reopened\"])")" = G1 ]'
: > "$T/pool.log"
run tick --prd "$T/prd-gf.json"
check "gate fail --story: routing goes on (no GATE_FAILED) and the story routes" \
  '[ "$(rc)" = 0 ] && ! grep -q GATE_FAILED "$T/out" && grep -q "^ROUTED G1 backend" "$T/out" && grep -q "guard test flags G1" "$T/queued/G1-backend.json"'
run accept --story G1 --handoff "$(handoff G1 backend backend-dev passed '[]')"
run tick --prd "$T/prd-gf.json"
run accept --story G1 --handoff "$(handoff G1 qa qa-tester passed '[{"index":0,"met":true,"evidence":"re-run"}]')"
run recheck --prd "$T/prd-gf.json" --story G1
check "gate fail --story: re-verifying the story makes the gate due again" \
  'grep -q "^VERIFIED G1" "$T/out" && grep -q "^RUN_GATE" "$T/out" && [ "$(pyget "$S/gate.json" "d[\"state\"]")" = due ] && grep -q "^- G1 verified after it was reopened (guard test flags G1)" "$S/report.md"'
run gate result fail --story G2 --note "x"
check "gate fail --story: a second failed gate naming another story reopens it too" \
  '[ "$(rc)" = 0 ] && [ "$(pyget "$S/gate.json" "\",\".join(d[\"reopened\"])")" = G2 ] && [ "$(pyget "$S/stories/G2.json" "d[\"state\"]")" = queued ]'
S="$T/state-gf2"; mkdir -p "$S/stories"
mkst H1 queued 0
run gate result fail --story H1 --note "x"
check "gate fail --story: a story reopen refuses leaves the gate unrecorded" '[ "$(rc)" = 1 ] && [ ! -f "$S/gate.json" ]'
run gate result fail --note "no story named"
check "gate fail without --story: today's behaviour (failed)" '[ "$(rc)" = 0 ] && grep -q "^GATE failed" "$T/out" && [ "$(pyget "$S/gate.json" "d[\"state\"]")" = failed ]'
S="$T/state"

# ==== fix pass 2: repo per story, base-branch cut, branch modes, concurrency, story-level go ====
# an empty path would make git -C "" commit in the caller's checkout: refuse it
gitc() { case "$1" in "$T"/*) ;; *) echo "gitc: refusing a repo outside the test dir: '$1'" >&2; return 1 ;; esac
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$2"; }
mkrepo() { mkdir -p "$1" && git -C "$1" init -q -b main && gitc "$1" "base"; }

# ---- repo per story: all three sources, both repo-list shapes ----
RA="$T/multi/alpha"; RB="$T/multi/beta"; mkrepo "$RA"; mkrepo "$RB"
cat > "$T/prd-multi.json" <<JSON
{"name":"multi","metadata":{"repoPath":"$RA","repos":[{"path":"$RA"},"$RB"]},"userStories":[
 {"id":"M1","title":"story repoPath","passes":false,"dependsOn":[],"repoPath":"$RB","files":["alpha/src/a.ts"],"worker_preference":["backend-dev"],"acceptanceCriteria":["m1"]},
 {"id":"M2","title":"first file by dir name","passes":false,"dependsOn":[],"files":["beta/src/b.ts","alpha/x.ts"],"worker_preference":["backend-dev"],"acceptanceCriteria":["m2"]},
 {"id":"M3","title":"first file absolute","passes":false,"dependsOn":[],"files":["$RB/lib/c.ts"],"worker_preference":["backend-dev"],"acceptanceCriteria":["m3"]},
 {"id":"M4","title":"metadata repoPath","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["m4"]}
]}
JSON
MS="$T/mstate"
for id in M1 M2 M3 M4; do "$PC" classify --prd "$T/prd-multi.json" --state "$MS" --story $id >/dev/null; done
check "repo: story repoPath wins over the first file" '[ "$(pyget "$MS/stories/M1.json" "d[\"repo\"]")" = "$RB" ]'
check "repo: owner of the first declared file (directory name)" '[ "$(pyget "$MS/stories/M2.json" "d[\"repo\"]")" = "$RB" ]'
check "repo: owner of the first declared file (absolute path)" '[ "$(pyget "$MS/stories/M3.json" "d[\"repo\"]")" = "$RB" ]'
check "repo: metadata.repoPath last" '[ "$(pyget "$MS/stories/M4.json" "d[\"repo\"]")" = "$RA" ]'
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); m=d["metadata"]; m["repoPaths"]=[m.pop("repos")[0]["path"], sys.argv[2]]; json.dump(d,open(sys.argv[3],"w"))' "$T/prd-multi.json" "$RB" "$T/prd-alias.json"
"$PC" classify --prd "$T/prd-alias.json" --state "$T/astate" --story M2 >/dev/null
check "repo: metadata.repoPaths[] alias read the same way" '[ "$(pyget "$T/astate/stories/M2.json" "d[\"repo\"]")" = "$RB" ]'

# ---- tick routes each story to its repo's worktree; a repo with no worktree is held ----
: > "$T/pool.log"
PC_MAX_STORIES=4 "$PC" tick --prd "$T/prd-multi.json" --state "$T/m2state" --worktree "$RA=$T/wtA" > "$T/out" 2>"$T/err"; trc=$?
check "no worktree for repo: held blocked_needs_owner, decision names the repo" \
  '[ $trc = 0 ] && [ "$(pyget "$T/m2state/stories/M1.json" "d[\"state\"]")" = blocked_needs_owner ] && grep -q "BLOCKED_OWNER M1 backend no_worktree" "$T/out" && grep -q "repo $RB" "$T/m2state/decisions/M1-blocked-backend.md"'
check "no worktree for repo: never routed to another repo's tree" '! grep -q "M1 backend" "$T/pool.log" && [ ! -f "$T/m2state/envelopes/M1-backend.json" ]'
check "alpha story routed to the alpha worktree with repo in the envelope" \
  '[ "$(pyget "$T/m2state/envelopes/M4-backend.json" "d[\"worktree\"]")" = "$T/wtA" ] && [ "$(pyget "$T/m2state/envelopes/M4-backend.json" "d[\"repo\"]")" = "$RA" ]'
check "concurrency: MAX_STORIES lowered to the worktrees in play" 'grep -q "^MAX_STORIES 1 PC_MAX_STORIES=4 lowered" "$T/out"'
PC_MAX_STORIES=4 "$PC" tick --prd "$T/prd-multi.json" --state "$T/m2state" --worktree "$RA=$T/wtA" > "$T/out2" 2>&1
check "concurrency: the MAX_STORIES line is printed once, not every tick" '! grep -q MAX_STORIES "$T/out2"'
"$PC" resolve --state "$T/m2state" --story M1 --as retry --note "beta worktree added" >/dev/null 2>&1
PC_MAX_STORIES=4 "$PC" tick --prd "$T/prd-multi.json" --state "$T/m2state" --worktree "$RA=$T/wtA" --worktree "$RB=$T/wtB" > "$T/out" 2>&1
check "after the owner adds the worktree and retries, the story routes to its own repo" \
  '[ "$(pyget "$T/m2state/envelopes/M1-backend.json" "d[\"worktree\"]")" = "$T/wtB" ] && grep -q "^MAX_STORIES 2 PC_MAX_STORIES=4" "$T/out"'

# ---- base-branch cut: origin present, origin absent, neither ----
BO="$T/cut/origin.git"; BL="$T/cut/local"; BC="$T/cut/other"
mkrepo "$BL"; git clone -q --bare "$BL" "$BO"; git -C "$BL" remote add origin "$BO"; git -C "$BL" fetch -q origin
git clone -q "$BO" "$BC"; gitc "$BC" "remote-new"; git -C "$BC" push -q origin HEAD:main
git -C "$BL" checkout -q -b unrelated; gitc "$BL" "unrelated head"
printf '{"name":"cutdemo","userStories":[{"id":"C1","title":"c","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["c"]}]}\n' > "$T/prd-cut.json"
wtc="$("$PC" worktree --state "$T/cstate" --repo "$BL" --shared --prd "$T/prd-cut.json" 2>"$T/err")"; crc=$?
check "cut: origin/<base> after a fetch, printed, never HEAD" \
  '[ $crc = 0 ] && grep -q "^CUT feature/cutdemo from origin/main " "$T/err" && [ "$(git -C "$wtc" rev-parse HEAD)" = "$(git -C "$BO" rev-parse main)" ] && git -C "$wtc" log --format=%s | grep -q remote-new && ! git -C "$wtc" log --format=%s | grep -q "unrelated head"'
BN="$T/cut/noorigin"; mkrepo "$BN"; gitc "$BN" "main tip"; git -C "$BN" checkout -q -b other; gitc "$BN" "other head"
wtn="$("$PC" worktree --state "$T/cstate2" --repo "$BN" --shared --prd "$T/prd-cut.json" 2>"$T/err")"
check "cut: local <base> when there is no origin" \
  'grep -q "^CUT feature/cutdemo from main " "$T/err" && [ "$(git -C "$wtn" rev-parse HEAD)" = "$(git -C "$BN" rev-parse main)" ]'
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["metadata"]={"baseBranch":"develop","branchName":"feat/x"}; json.dump(d,open(sys.argv[2],"w"))' "$T/prd-cut.json" "$T/prd-dev.json"
BX="$T/cut/neither"; mkrepo "$BX"
"$PC" worktree --state "$T/cstate3" --repo "$BX" --shared --prd "$T/prd-dev.json" >/dev/null 2>"$T/err"; xrc=$?
check "cut: neither ref -> exit 1 with a clear message, no branch made" \
  '[ $xrc = 1 ] && grep -q "neither origin/develop nor develop exists" "$T/err" && ! git -C "$BX" show-ref --verify --quiet refs/heads/feat/x'

# ---- default: one feature branch per repo, stories commit on it in dependency order ----
FR="$T/feat/repo"; mkrepo "$FR"
cat > "$T/prd-feat.json" <<JSON
{"name":"feat","metadata":{"repoPath":"$FR"},"userStories":[
 {"id":"F1","title":"f1","priority":1,"passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["f1"]},
 {"id":"F2","title":"f2","priority":2,"passes":false,"dependsOn":["F1"],"worker_preference":["backend-dev"],"acceptanceCriteria":["f2"]},
 {"id":"F3","title":"f3","priority":3,"passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["f3"]}
]}
JSON
FS="$T/fstate"
fwt="$("$PC" worktree --state "$FS" --repo "$FR" --shared --prd "$T/prd-feat.json" 2>/dev/null)"
PC_MAX_STORIES=3 "$PC" tick --prd "$T/prd-feat.json" --state "$FS" --worktree "$FR=$fwt" > "$T/out" 2>&1
check "feature branch: one story in flight on the repo branch" \
  '[ "$(pyget "$FS/stories/F1.json" "d[\"state\"]")" = in_flight ] && [ ! -f "$FS/stories/F3.json" ] && grep -q "^MAX_STORIES 1" "$T/out"'
check "feature branch: envelope names feature/<project>" '[ "$(pyget "$FS/envelopes/F1-backend.json" "d[\"branch\"]")" = feature/feat ]'
gitc "$fwt" "F1 work"
"$PC" accept --state "$FS" --story F1 --handoff "$(handoff F1 backend backend-dev passed '[{"index":0,"met":true,"evidence":"e"}]')" >/dev/null
"$PC" recheck --prd "$T/prd-feat.json" --state "$FS" --story F1 >/dev/null
PC_MAX_STORIES=3 "$PC" tick --prd "$T/prd-feat.json" --state "$FS" --worktree "$FR=$fwt" > "$T/out" 2>&1
check "feature branch: the dependent story routes next in the same worktree and sees its dependency's commit" \
  '[ "$(pyget "$FS/stories/F2.json" "d[\"state\"]")" = in_flight ] && [ "$(pyget "$FS/envelopes/F2-backend.json" "d[\"worktree\"]")" = "$fwt" ] && git -C "$fwt" log --format=%s | grep -q "F1 work" && [ ! -f "$FS/stories/F3.json" ]'

# ---- --story-branches: stacked on the last verified dependency; missing branch refused ----
KR="$T/stack/repo"; mkrepo "$KR"
cat > "$T/prd-stack.json" <<JSON
{"name":"stack","metadata":{"repoPath":"$KR"},"userStories":[
 {"id":"K1","title":"k1","priority":1,"passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["k1"]},
 {"id":"K2","title":"k2","priority":2,"passes":false,"dependsOn":["K1"],"worker_preference":["backend-dev"],"acceptanceCriteria":["k2"]},
 {"id":"K3","title":"k3","priority":3,"passes":false,"dependsOn":["K1"],"worker_preference":["backend-dev"],"acceptanceCriteria":["k3"]}
]}
JSON
KS="$T/kstate"
PC_MAX_STORIES=1 "$PC" tick --prd "$T/prd-stack.json" --state "$KS" --worktree "$KR=$KR" --story-branches > "$T/out" 2>&1
k1wt="$(pyget "$KS/stories/K1.json" "d[\"worktree\"]")"
check "stacked: the first story is cut from the base" 'grep -q "^CUT pipeline/K1 from main " "$T/out" && [ "$k1wt" != "$KR" ]'
gitc "$k1wt" "K1 work"
"$PC" accept --state "$KS" --story K1 --handoff "$(handoff K1 backend backend-dev passed '[{"index":0,"met":true,"evidence":"e"}]')" >/dev/null
"$PC" recheck --prd "$T/prd-stack.json" --state "$KS" --story K1 >/dev/null
PC_MAX_STORIES=1 "$PC" tick --prd "$T/prd-stack.json" --state "$KS" --worktree "$KR=$KR" --story-branches > "$T/out" 2>&1
k2wt="$(pyget "$KS/stories/K2.json" "d[\"worktree\"]")"
check "stacked: a dependent story is cut from its dependency's branch and sees its commit" \
  'grep -q "^CUT pipeline/K2 from pipeline/K1 " "$T/out" && git -C "$k2wt" log --format=%s | grep -q "K1 work" && [ "$(pyget "$KS/stories/K2.json" "d[\"stacked_on\"]")" = K1 ]'
git -C "$KR" worktree remove --force "$k1wt"; git -C "$KR" branch -q -D pipeline/K1
PC_MAX_STORIES=2 "$PC" tick --prd "$T/prd-stack.json" --state "$KS" --worktree "$KR=$KR" --story-branches > "$T/out" 2>&1
check "stacked: a story whose dependency branch is missing is not routed" \
  '[ "$(pyget "$KS/stories/K3.json" "d[\"state\"]")" = blocked_needs_owner ] && grep -q "BLOCKED_OWNER K3 backend dependency_branch_missing" "$T/out" && [ ! -f "$KS/envelopes/K3-backend.json" ]'

# ---- story-level go: explicit key, alias, detector, go, resolve, park, summaries ----
cat > "$T/prd-go.json" <<'JSON'
{"name":"go","userStories":[
 {"id":"G1","title":"explicit","passes":false,"dependsOn":[],"approval":"explicit","worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["g1"]},
 {"id":"G2","title":"alias","passes":false,"dependsOn":[],"needsApproval":true,"worker_preference":["backend-dev"],"acceptanceCriteria":["g2"]},
 {"id":"G3","title":"merge ac","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["Merge the feature branch into main after review"]},
 {"id":"G4","title":"deploy file","passes":false,"dependsOn":[],"files":["infra/deploy.yml"],"worker_preference":["backend-dev"],"acceptanceCriteria":["g4"]},
 {"id":"G5","title":"plain","passes":false,"dependsOn":[],"files":["src/product.ts"],"worker_preference":["backend-dev"],"acceptanceCriteria":["Product page shows the price"]},
 {"id":"G6","title":"qa release","passes":false,"dependsOn":[],"worker_preference":["qa-tester"],"acceptanceCriteria":["Smoke test production after the release"]}
]}
JSON
GS="$T/gstate"; : > "$T/pool.log"
for id in G1 G2 G3 G4 G5 G6; do
  "$PC" classify --prd "$T/prd-go.json" --state "$GS" --story $id --worktree "$T/wt" >/dev/null
  "$PC" route --prd "$T/prd-go.json" --state "$GS" --story $id > "$T/out-$id" 2>&1; echo $? > "$T/rc-$id"
done
check "go: approval explicit held awaiting_go (exit 10), decision item, nothing queued" \
  '[ "$(cat "$T/rc-G1")" = 10 ] && grep -q "^AWAITING_GO G1 backend" "$T/out-G1" && [ "$(pyget "$GS/stories/G1.json" "d[\"state\"]")" = awaiting_go ] && grep -q "approval: explicit" "$GS/decisions/G1-go.md" && ! grep -q "G1 " "$T/pool.log"'
check "go: needsApproval alias held" '[ "$(pyget "$GS/stories/G2.json" "d[\"state\"]")" = awaiting_go ]'
check "go: detector flags merging to the base branch" '[ "$(pyget "$GS/stories/G3.json" "d[\"state\"]")" = awaiting_go ] && grep -q "release detector" "$GS/decisions/G3-go.md"'
check "go: detector flags a deploy file" '[ "$(pyget "$GS/stories/G4.json" "d[\"state\"]")" = awaiting_go ]'
check "go: an ordinary story is not flagged" '[ "$(cat "$T/rc-G5")" = 0 ] && [ "$(pyget "$GS/stories/G5.json" "d[\"state\"]")" = in_flight ]'
check "go: a release story on qa-tester (approval_required false) is held" '[ "$(pyget "$GS/stories/G6.json" "d[\"state\"]")" = awaiting_go ]'
"$PC" release --state "$GS" --worker backend-dev >/dev/null 2>&1
check "go: whole-run worker approval does not release it" '[ "$(pyget "$GS/stories/G1.json" "d[\"state\"]")" = awaiting_go ]'
"$PC" release --state "$GS" --story G1 --worker backend-dev >/dev/null 2>"$T/err"; rrc=$?
check "go: release --story refuses an awaiting_go story" '[ $rrc = 1 ] && grep -q "run go --story G1" "$T/err"'
"$PC" report final --state "$GS" > "$T/out" 2>&1
check "go: FINAL counts and lists awaiting_go stories" 'grep -q "awaiting go 5," "$T/out" && grep -q "awaiting go: G1 (approval: explicit; run go --story G1)" "$T/out"'
"$PC" go --state "$GS" --story G1 > "$T/out" 2>&1; grc=$?
"$PC" route --prd "$T/prd-go.json" --state "$GS" --story G1 > "$T/out2" 2>&1; grc2=$?
check "go: go releases it and the next route queues it" '[ $grc = 0 ] && grep -q "^GO G1" "$T/out" && [ $grc2 = 0 ] && grep -q "^ROUTED G1 backend" "$T/out2" && grep -q "status: go" "$GS/decisions/G1-go.md"'
"$PC" go --state "$GS" --story G1 > "$T/out" 2>&1
check "go: repeating go prints ALREADY" 'grep -q "^ALREADY go G1" "$T/out"'
"$PC" go --state "$GS" --story G5 >/dev/null 2>&1; g5=$?
check "go: refuses a story that is not awaiting_go" '[ $g5 = 1 ]'
"$PC" resolve --state "$GS" --story G2 --as accepted-partial --note "owner ships it by hand" --prd "$T/prd-go.json" > "$T/out" 2>&1
check "go: resolve accepted-partial works on an awaiting_go story" '[ "$(pyget "$GS/stories/G2.json" "d[\"state\"]")" = accepted_partial ] && grep -q "resolved: accepted-partial" "$GS/decisions/G2-go.md"'
"$PC" park --state "$GS" --story G3 --note "later" > "$T/out" 2>&1
check "go: park works on an awaiting_go story" '[ "$(pyget "$GS/stories/G3.json" "d[\"state\"]")" = parked ] && grep -q "status: parked" "$GS/decisions/G3-go.md"'
"$PC" unpark --state "$GS" --story G3 > "$T/out" 2>&1
check "go: unpark restores awaiting_go" '[ "$(pyget "$GS/stories/G3.json" "d[\"state\"]")" = awaiting_go ]'
"$PC" resolve --state "$GS" --story G4 --as retry --note "re-read" --prd "$T/prd-go.json" >/dev/null 2>&1
"$PC" route --prd "$T/prd-go.json" --state "$GS" --story G4 > "$T/out" 2>&1
check "go: resolve retry re-reads the story and it is held for the go again" '[ "$(pyget "$GS/stories/G4.json" "d[\"state\"]")" = awaiting_go ] && grep -q "^AWAITING_GO G4" "$T/out"'

# ---- run worktrees: default under workspace/worktrees/<project>/, repos/ refused ----
YR="$T/ytree/app"; mkrepo "$YR"
printf '{"name":"wtdemo","userStories":[{"id":"Y1","title":"y","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["y"]}]}\n' > "$T/prd-wt.json"
ywt="$("$PC" worktree --state "$T/ystate" --repo "$YR" --shared --prd "$T/prd-wt.json" 2>/dev/null)"
check "worktree default: <HQ>/workspace/worktrees/<project>/<repo-name>/" \
  '[ "$ywt" = "$(cd "$T/hq" && pwd -P)/workspace/worktrees/wtdemo/app" ] && [ -d "$ywt" ] && [ "$(git -C "$ywt" rev-parse --abbrev-ref HEAD)" = feature/wtdemo ]'
"$PC" classify --prd "$T/prd-wt.json" --state "$T/ystate" --story Y1 >/dev/null 2>&1
ysw="$("$PC" worktree --state "$T/ystate" --repo "$YR" --shared --story-branches --story Y1 --prd "$T/prd-wt.json" 2>/dev/null)"
check "worktree default with --story-branches: <project>/<repo-name>-<story>/" \
  '[ "$ysw" = "$(cd "$T/hq" && pwd -P)/workspace/worktrees/wtdemo/app-Y1" ] && [ -d "$ysw" ]'
yn="$("$PC" worktree --state "$T/ystate2" --repo "$YR" --prd "$T/prd-wt.json" 2>/dev/null)"
check "worktree without --shared but with --prd cuts at the default target too" '[ "$yn" = "$ywt" ]'
# a repo under <HQ>/repos/ used in place, or an explicit --worktree that resolves there
HR="$T/hq/repos/private/app2"; mkrepo "$HR"
"$PC" worktree --state "$T/ystate3" --repo "$HR" >/dev/null 2>"$T/err"; yrc=$?
check "worktree: the repo itself under repos/ is refused (exit 2) and the message explains the guard" \
  '[ $yrc = 2 ] && grep -q "core Write/Edit guard blocks editor-tool writes" "$T/err" && grep -q -- "--allow-repos-worktree" "$T/err" && grep -q "workspace/worktrees/<project>/<repo-name>/" "$T/err"'
"$PC" worktree --state "$T/ystate3" --repo "$YR" --shared --prd "$T/prd-wt.json" --worktree "$T/hq/repos/private/app-wt" >/dev/null 2>"$T/err"; yrc=$?
check "worktree: an explicit --worktree under repos/ is refused and nothing is cut" \
  '[ $yrc = 2 ] && grep -q "refusing worktree" "$T/err" && [ ! -d "$T/hq/repos/private/app-wt" ]'
"$PC" tick --prd "$T/prd-wt.json" --state "$T/ystate4" --worktree "$YR=$T/hq/repos/private/app2" >"$T/out" 2>"$T/err"; yrc=$?
check "tick: --worktree <repo>=<dir under repos/> is refused, nothing routed" \
  '[ $yrc = 2 ] && grep -q "refusing worktree .*repos/private/app2" "$T/err" && [ ! -f "$T/ystate4/envelopes/Y1-backend.json" ]'
"$PC" tick --prd "$T/prd-wt.json" --state "$T/ystate5" --worktree "$T/hq/repos/private/app2" >"$T/out" 2>"$T/err"; yrc=$?
check "tick: a bare --worktree under repos/ is refused" '[ $yrc = 2 ] && grep -q "refusing worktree" "$T/err"'
"$PC" tick --prd "$T/prd-wt.json" --state "$T/ystate6" --worktree "$T/hq/repos/private/app2" --allow-repos-worktree >"$T/out" 2>"$T/err"; yrc=$?
check "tick --allow-repos-worktree: routes into the tree under repos/" \
  '[ $yrc = 0 ] && grep -q "^ROUTED Y1 backend" "$T/out" && [ "$(pyget "$T/ystate6/run.json" "d[\"allow_repos_worktree\"]")" = True ]'
check "--allow-repos-worktree: the envelope carries the shell/apply_patch constraint line" \
  'pyget "$T/ystate6/envelopes/Y1-backend.json" "\"\\n\".join(d[\"constraints\"])" | grep -q "^This worktree is under repos/, where the core Write/Edit guard blocks the editor tools: make every file edit through the shell or apply_patch"'
"$PC" tick --prd "$T/prd-wt.json" --state "$T/ystate7" --worktree "$ywt" >"$T/out" 2>"$T/err"
check "a worktree outside repos/ gets no repos constraint line" \
  'grep -q "^ROUTED Y1 backend" "$T/out" && ! grep -q "under repos/" "$T/ystate7/envelopes/Y1-backend.json"'
check "the repos/ check lives in one function" '[ "$(grep -c "^function repos_worktree" "$PC")" = 1 ] && [ "$(grep -c "workspace\", \"worktrees\"" "$PC")" -le 2 ]'

# ---- interrupt / stop ----
IS="$T/istate"; mkdir -p "$T/ilane/inbox/pending" "$T/ilane/inbox/active"
printf '{"name":"idemo","userStories":[{"id":"I1","title":"i1","passes":false,"dependsOn":[],"worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["i"]},{"id":"I2","title":"i2","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["j"]}]}\n' > "$T/prd-i.json"
# One worker loop lane receives both in-flight phases.
for i in I1 I2; do
  "$PC" classify --prd "$T/prd-i.json" --state "$IS" --story "$i" --worktree "$T/wt" >/dev/null 2>&1
  PC_HQ="$T/bin/hq" "$PC" route --prd "$T/prd-i.json" --state "$IS" --story "$i" >/dev/null 2>&1
done
PC_HQ="$T/bin/hq" "$PC" interrupt --state "$IS" --note "test stop" > "$T/out" 2>&1
check "interrupt: both in-flight stories marked interrupted" \
  '[ "$(pyget "$IS/stories/I1.json" "d[\"state\"]")" = interrupted ] && [ "$(pyget "$IS/stories/I2.json" "d[\"state\"]")" = interrupted ]'
check "interrupt: phase, time and reason recorded" \
  '[ "$(pyget "$IS/stories/I1.json" "d[\"interrupted\"][\"phase\"]")" = backend ] && [ "$(pyget "$IS/stories/I1.json" "d[\"interrupted\"][\"at\"]")" = 2026-09-21T14:13:20Z ] && [ "$(pyget "$IS/stories/I1.json" "d[\"interrupted\"][\"reason\"]")" = "test stop" ]'
check "interrupt: the unpicked envelope is withdrawn, the picked-up one is left" \
  'grep -q "^INTERRUPTED I1 backend withdrawn" "$T/out" && grep -q "^INTERRUPTED I2 backend picked_up" "$T/out" && grep -q "lanes interrupt .*--story I1 --phase backend" "$T/pool.log" && grep -q "lanes interrupt .*--story I2 --phase backend" "$T/pool.log"'
"$PC" report final --state "$IS" > "$T/out" 2>&1
check "interrupt: FINAL counts and lists the interrupted stories" \
  'grep -q "interrupted 2," "$T/out" && grep -q "interrupted, routed first on the next driver start: I1 at backend (2026-09-21T14:13:20Z), I2 at backend" "$T/out"'
printf '{"schema":"hq-phase-handoff/v1","story_id":"I2","phase":"backend","worker_id":"backend-dev","status":"failed","summary":"late"}\n' > "$IS/handoffs/I2-backend.json"
PC_HQ="$T/bin/hq" PC_MAX_STORIES=2 "$PC" tick --prd "$T/prd-i.json" --state "$IS" --worktree "$T/wt" > "$T/out" 2>&1
check "tick: interrupted stories are routed again at the interrupted phase" \
  'grep -q "^ROUTED I1 backend" "$T/out" && grep -q "^ROUTED I2 backend" "$T/out" && [ "$(pyget "$IS/stories/I1.json" "d[\"state\"]")" = in_flight ]'
check "tick: the envelope says resumed_after_interrupt and validates" \
  '[ "$(pyget "$IS/envelopes/I1-backend.json" "d[\"resumed_after_interrupt\"]")" = True ] && "$HERE/../pipeline-envelope.sh" validate --kind envelope "$IS/envelopes/I1-backend.json" >/dev/null 2>&1'
check "tick: a handoff that landed after the stop is set aside and named as prior_handoff" \
  '[ ! -f "$IS/handoffs/I2-backend.json" ] && [ "$(pyget "$IS/envelopes/I2-backend.json" "d[\"prior_handoff\"]")" = "$IS/handoffs/I2-backend.interrupted.1.json" ] && [ -f "$IS/handoffs/I2-backend.interrupted.1.json" ]'
check "tick: once routed again it is no longer listed as interrupted" \
  '[ "$(pyget "$IS/stories/I1.json" "d[\"interrupted\"][\"routed\"]")" = True ] && ! "$PC" report final --state "$IS" 2>&1 | grep -q "routed first"'
# interrupt keeps a phase whose handoff already finished it; stop with no live driver interrupts in place
printf '{"schema":"hq-phase-handoff/v1","story_id":"I1","phase":"backend","worker_id":"backend-dev","status":"passed","summary":"done"}\n' > "$IS/handoffs/I1-backend.json"
PC_HQ="$T/bin/hq" "$PC" stop --state "$IS" --note "owner stop" > "$T/out" 2>&1
check "stop with no live driver: interrupts here; a finished phase is kept for accept" \
  'grep -q "^STOPPED no live driver" "$T/out" && grep -q "^KEPT I1 backend handoff-present" "$T/out" && [ "$(pyget "$IS/stories/I1.json" "d[\"state\"]")" = in_flight ] && [ "$(pyget "$IS/stories/I2.json" "d[\"state\"]")" = interrupted ] && [ ! -f "$IS/driver/stop.json" ]'
sleep 30 & lpid=$!
mkdir -p "$IS/driver"; echo "$lpid" > "$IS/driver/driver.pid"
PC_HQ="$T/bin/hq" "$PC" stop --state "$IS" --note "owner stop" > "$T/out" 2>&1
check "stop with a live driver: writes driver/stop.json as a stop envelope" \
  'grep -q "^STOP_REQUESTED " "$T/out" && [ "$(pyget "$IS/driver/stop.json" "d[\"kind\"]")" = stop ] && [ "$(pyget "$IS/driver/stop.json" "d[\"note\"]")" = "owner stop" ]'
kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null

# ---- never spawns ----
check "no child-agent spawn in conductor" '! grep -nE "claude -p|codex exec|grok -p|Task\(" "$PC"'

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ $fail -eq 0 ]
