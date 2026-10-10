#!/usr/bin/env bash
# Pins /execute-task and interactive /run-project to the HQ lanes contract.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILLS="${HQ_ORCH_SKILLS_DIR:-$ROOT/.claude/skills}"
EXEC_TASK="$SKILLS/execute-task/SKILL.md"
RUN_PROJECT="$SKILLS/run-project/SKILL.md"
CONDUCT="$SKILLS/conduct/dispatch.md"
PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok — $1"; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[ -f "$EXEC_TASK" ] || fail "missing $EXEC_TASK"
[ -f "$RUN_PROJECT" ] || fail "missing $RUN_PROJECT"
[ -f "$CONDUCT" ] || fail "missing $CONDUCT"
echo "plain /conduct: every session pin reaches lanes create"
for pin in '--provider' 'conduct_engine' '--model' 'conduct_child_model' '--effort' 'conduct_child_effort'; do
  grep -Fq -- "$pin" "$CONDUCT" || fail "plain /conduct lane create is missing session pin reference '$pin'"
done
grep -qi 'A user flag overrides' "$CONDUCT" || fail 'explicit lane flags must override session pins'
ok "provider, model, and effort session pins are documented for every conduct lane"
awk '/^## Step 3P /{exit} {print}' "$RUN_PROJECT" > "$TMP/run-project-interactive.md"
RUN_INTERACTIVE="$TMP/run-project-interactive.md"
flatten() { tr '\n' ' ' < "$1" | tr -s ' '; }
flatten "$EXEC_TASK" > "$TMP/execute.flat"
flatten "$RUN_INTERACTIVE" > "$TMP/run.flat"
EXEC_FLAT="$TMP/execute.flat"; RUN_FLAT="$TMP/run.flat"
echo "execute-task: every worker phase uses the bound story lane"
if grep -Fq 'spawn a sub-agent via the Task tool' "$EXEC_TASK"; then
  fail "execute-task still describes Task-based phase dispatch"
fi
for needle in 'hq lanes create' '--company "{company}"' '--project "{project}"' '--story "{task.id}"' '--worker "{worker.id}"' '--brief-file' '--senior "session:{session-id}"' '--json'; do
  grep -Fq -- "$needle" "$EXEC_TASK" || fail "execute-task lane dispatch missing '$needle'"
done
grep -qi 'only when the selected worker profile' "$EXEC_FLAT" || fail "provider/model/effort flags must remain conditional on worker pins"
ok "create carries company, project, story, worker, brief, and invoking senior"
echo "execute-task: live follow-up and terminal results use HQ lanes"
grep -Fq 'hq lanes message' "$EXEC_TASK" || fail "live lane follow-up must use lanes message"
grep -Fq 'hq lanes wait' "$EXEC_TASK" || fail "phase must wait through HQ lanes"
grep -qi 'policy-required detached watcher' "$EXEC_TASK" || fail "phase must arm and verify the detached lane watcher"
grep -Fq 'hq lanes list --json' "$EXEC_TASK" || fail "phase result must use lanes list"
grep -Fq 'last_envelope.ref' "$EXEC_TASK" || fail "phase must read the lane envelope"
grep -qi 'handoffs.jsonl' "$EXEC_FLAT" || fail "phase handoff file must remain durable"
grep -q 'from_worker.*to_worker.*timestamp' "$EXEC_FLAT" || fail "handoff format fields must remain documented"
ok "live follow-up, wait, envelope result, and handoff format are retained"
echo "execute-task: inline Codex reviewer and quality gates remain"
grep -Fq 'codex review --uncommitted' "$EXEC_TASK" || fail "inline Codex review path was removed"
grep -Fq 'verification.post_execute' "$EXEC_TASK" || fail "worker back-pressure checks were removed"
grep -Fq 'qualityGates' "$EXEC_TASK" || fail "project quality gates were removed"
grep -Fq 'The orchestrator does not commit work for you.' "$EXEC_TASK" || fail "a missing worker commit must return to the same lane"
if grep -Fq 'commits them on your behalf' "$EXEC_TASK"; then
  fail "execute-task must not commit worker changes in the parent"
fi
ok "review and quality gates remain"
echo "interactive run-project: each story uses the worker lane mapping"
grep -Fq 'hq lanes create' "$RUN_INTERACTIVE" || fail "story loop must create worker lanes"
grep -Fq 'hq lanes message' "$RUN_INTERACTIVE" || fail "live story lane must accept follow-up via message"
grep -Fq 'hq lanes wait' "$RUN_INTERACTIVE" || fail "story loop must wait through HQ lanes"
grep -Fq 'hq lanes list --json' "$RUN_INTERACTIVE" || fail "story results must be read from lanes list"
grep -Fq 'hq lanes list --json --senior "session:$(jq -r .session_id' "$RUN_PROJECT" \
  || fail "resumed story lanes must be listed under the original senior session"
grep -Fq '/execute-task {project}/{story-id}' "$RUN_INTERACTIVE" || fail "story brief must run execute-task"
grep -Fq 'session:{session-id}' "$RUN_INTERACTIVE" || fail "invoking session must be lane senior"
grep -Fq 'capacity refusal leaves the story queued' "$RUN_FLAT" || fail "admission refusal must keep story queued"
grep -Fq 'hq lanes story' "$RUN_INTERACTIVE" || fail "status updates must use board/lane story path"
grep -Fq 'Do not add status fields to local `prd.json`' "$RUN_INTERACTIVE" || fail "must not add local PRD status writes"
ok "story dispatch, result validation, status path, and admission handling are documented"
echo "owned files do not call legacy conduct helpers"
for f in "$EXEC_TASK" "$RUN_INTERACTIVE"; do
  if [ "$f" = "$RUN_INTERACTIVE" ]; then
    scan_text="$(sed -n '/^# Run Project/,$p' "$f")"
  else
    scan_text="$(cat "$f")"
  fi
  if printf '%s\n' "$scan_text" | grep -qE 'conduct-(pool|inbox|link|reap|lane-status|lane-launch|lane-wait)\.sh'; then
    fail "$(basename "$f") still calls a conduct helper"
  fi
done
ok "legacy conduct calls cannot return to these paths"
echo "tests use a fake hq executable and never invoke the installed CLI"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HQ_TEST_CAPTURE"
case "$*" in
  'lanes create'*) printf '%s\n' '{"ok":true,"lane_id":"lane-test-001","state":"queued"}' ;;
  *) printf '%s\n' '{"ok":true}' ;;
esac
FAKE
chmod +x "$TMP/bin/hq"
export HQ_TEST_CAPTURE="$TMP/argv.log"
PATH="$TMP/bin:$PATH" hq lanes create --company indigo --project hq-work --story CL-6e --worker backend-dev --brief-file /tmp/phase.md --senior session:session-test --json > "$TMP/result.json"
grep -Fq -- '--company indigo --project hq-work --story CL-6e --worker backend-dev' "$HQ_TEST_CAPTURE" || fail "fake hq did not capture the lane mapping"
grep -Fq '"lane_id":"lane-test-001"' "$TMP/result.json" || fail "fake hq did not return canned JSON"
ok "the fixture records argv and returns canned JSON without calling real hq"

echo "run-project --pipeline: cap refusal, live-children bound, relay, recovery, stop"
awk '/^## Step 3P /{f=1} /^## Step 4 /{f=0} f' "$RUN_PROJECT" > "$TMP/pipe.md"
[ -s "$TMP/pipe.md" ] || fail "run-project has no Step 3P pipeline section"
flatten "$TMP/pipe.md" > "$TMP/pipe.flat"; PIPE_FLAT="$TMP/pipe.flat"
grep -q -- '--pipeline' <(sed -n '1,6p' "$RUN_PROJECT") \
  || fail "argument-hint must list --pipeline"
grep -q -- '- `--pipeline` —' "$RUN_PROJECT" \
  || fail "Step 1 must document the --pipeline flag"
head -30 "$RUN_PROJECT" | flatten /dev/stdin > "$TMP/head.flat"
grep -qi 'Pipeline mode (`--pipeline`) live children' "$TMP/head.flat" \
  || fail "the header must state the pipeline-mode live-children bound"
grep -qi 'one loop lane per confirmed worker-table row, plus the regression-gate lane' "$TMP/head.flat" \
  && ! grep -q 'CONDUCT_POOL_CAP' "$TMP/head.flat" \
  || fail "the pipeline bound must name rows + gate without a retired local cap"
grep -qi 'driver that routes phases is a detached script, not a lane, and takes no lane slot' "$TMP/head.flat" \
  || fail "the header must say the driver takes no lane slot"
grep -qi 'one `hq lanes` loop lane' "$PIPE_FLAT" \
  || fail "pipeline mode must allocate one loop lane per worker"
grep -qi 'The CLI applies lane capacity and company admission' "$PIPE_FLAT" \
  || fail "pipeline lane admission must use hq-cli capacity controls"
grep -qi 'admission or capacity error code, the story stays queued and the driver retries' "$PIPE_FLAT" \
  || fail "pipeline capacity refusals must leave work queued for the next tick"
grep -qi 'The driver itself is not a lane' "$PIPE_FLAT" \
  || fail "the detached driver must not consume a lane slot"
ok "pipeline mode delegates lane capacity to hq lanes and retries admission refusals"

grep -q 'report.md' "$PIPE_FLAT" && grep -qi 'per-story report lines' "$PIPE_FLAT" \
  || fail "the parent must relay the conductor's per-story report lines"
grep -q '/decision-queue' "$PIPE_FLAT" \
  && grep -q 'workspace/sessions/<id>/decisions.jsonl' "$PIPE_FLAT" \
  && grep -q 'hq lanes questions list' "$PIPE_FLAT" \
  || fail "decision items and lane questions must reach the decision queue"
ok "conductor report lines and decision items are relayed"

grep -qi 'After a parent compaction, recover from disk' "$PIPE_FLAT" \
  && grep -q '{state}/stories/' "$PIPE_FLAT" \
  && grep -q '{state}/driver/' "$PIPE_FLAT" \
  && grep -q 'hq lanes list --json' "$PIPE_FLAT" \
  && grep -q '{state}/lanes.json' "$PIPE_FLAT" \
  || fail "the parent must rebuild run state from its files and mapped hq lanes after compaction"
ok "compaction recovery reads the conductor's state dir and mapped hq lanes"

grep -q 'driver stops each lane id' "$PIPE_FLAT" \
  && grep -q 'clears the mapping after confirmation' "$PIPE_FLAT" \
  || fail "run end must stop each mapped lane and clear confirmed mappings"
grep -q 'loop state as `stopped` or the lane is absent' "$PIPE_FLAT" \
  || fail "run end must confirm terminal or absent mapped lanes"
ok "run end stops mapped lanes and clears mappings after confirmation"
echo
printf 'orchestrator-skills-use-pool.test.sh: %s checks passed\n' "$PASS"
