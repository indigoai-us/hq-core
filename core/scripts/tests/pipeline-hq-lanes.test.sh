#!/usr/bin/env bash
# Focused routing contract for pipeline loop lanes. Every lanes call uses fake hq.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/pipeline-hq-lanes.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/workers/backend-dev" "$T/state" "$T/hq/core/scripts"
cat >"$T/hq/core/scripts/hq-session.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *current*) printf 'test-session\n' ;; *company_slug*) printf 'indigo\n' ;; esac
EOF
chmod +x "$T/hq/core/scripts/hq-session.sh"
cat >"$T/workers/backend-dev/worker.yaml" <<'EOF'
worker:
  id: backend-dev
  role: implementer
EOF
cat >"$T/prd.json" <<'EOF'
{"name":"lane-test","userStories":[
 {"id":"A","title":"first","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["works"]},
 {"id":"B","title":"second","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["works"]}
]}
EOF
cat >"$T/bin/hq" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FAKE_HQ_LOG"
case "$1 $2" in
  "lanes create")
    if [ -n "${CREATE_ERROR:-}" ]; then printf '{"ok":false,"error":"%s"}\n' "$CREATE_ERROR"; exit 0; fi
    worker=""; while [ $# -gt 0 ]; do [ "$1" = --worker ] && { worker="$2"; shift 2; continue; }; shift; done
    printf '{"ok":true,"lane_id":"lane-%s"}\n' "$worker"
    printf '{"ok":true,"action":"list","lanes":[{"lane_id":"lane-%s","company":{"slug":"indigo"},"project_id":"lane-test","worker":"%s","loop":{"state":"waiting","queue_depth":0}}]}\n' "$worker" "$worker" >"$FAKE_HQ_LIST" ;;
  "lanes enqueue")
    envelope=""; while [ $# -gt 0 ]; do [ "$1" = --envelope ] && { envelope="$2"; shift 2; continue; }; shift; done
    if [ -n "${ENQUEUE_ERROR:-}" ] && ! jq -e '.id | contains(".r")' "$envelope" >/dev/null; then printf '{"ok":false,"error":"%s"}\n' "$ENQUEUE_ERROR"; exit 0; fi
    cp "$envelope" "$FAKE_HQ_ENQUEUED/$(basename "$envelope")"
    printf '{"ok":true,"action":"enqueue"}\n' ;;
  "lanes interrupt")
    story=""; phase=""; while [ $# -gt 0 ]; do case "$1" in --story) story="$2"; shift 2;; --phase) phase="$2"; shift 2;; *) shift;; esac; done
    if [ "${INTERRUPT_MODE:-withdrawn}" = already_picked_up ]; then printf '{"ok":true,"withdrawn":[],"already_picked_up":["%s-%s"]}\n' "$story" "$phase"
    else printf '{"ok":true,"withdrawn":["%s-%s"],"already_picked_up":[]}\n' "$story" "$phase"; fi ;;
  "lanes stop") printf '{"ok":true,"action":"stop"}\n' ;;
  "lanes list") cat "${FAKE_HQ_LIST:-/dev/null}" ;;
  *) printf '{"ok":false,"error":"unexpected_call"}\n'; exit 1 ;;
esac
EOF
chmod +x "$T/bin/hq"
export PATH="$T/bin:$PATH" PC_HQ="$T/bin/hq" PC_HQ_ROOT="$T/hq" PC_WORKERS_ROOT="$T/workers"
export HQ_SESSION_ID="01a11fa9-047c-7163-b047-ccfef5a5ac36" FAKE_HQ_LOG="$T/hq.log" FAKE_HQ_ENQUEUED="$T/enqueued" FAKE_HQ_LIST="$T/list.json"
mkdir -p "$FAKE_HQ_ENQUEUED"
"$ROOT/core/scripts/pipeline-conductor.sh" classify --prd "$T/prd.json" --state "$T/state" --story A >/dev/null
"$ROOT/core/scripts/pipeline-conductor.sh" classify --prd "$T/prd.json" --state "$T/state" --story B >/dev/null
"$ROOT/core/scripts/pipeline-conductor.sh" route --prd "$T/prd.json" --state "$T/state" --story A >/dev/null
"$ROOT/core/scripts/pipeline-conductor.sh" route --prd "$T/prd.json" --state "$T/state" --story B >/dev/null
[ "$(grep -c '^lanes create ' "$FAKE_HQ_LOG")" = 1 ]
[ "$(grep -c '^lanes enqueue ' "$FAKE_HQ_LOG")" = 2 ]
jq -e '.id == "A-backend" and (.result_path | contains("A-backend.json"))' "$FAKE_HQ_ENQUEUED/A-backend.json" >/dev/null

jq '.state = "queued"' "$T/state/stories/A.json" >"$T/story.tmp" && mv "$T/story.tmp" "$T/state/stories/A.json"
jq 'del(."backend-dev")' "$T/state/lanes.json" >"$T/lanes.tmp" && mv "$T/lanes.tmp" "$T/state/lanes.json"
CREATE_ERROR=admission_denied; export CREATE_ERROR
set +e
"$ROOT/core/scripts/pipeline-conductor.sh" route --prd "$T/prd.json" --state "$T/state" --story A >"$T/retry.out" 2>&1
rc=$?
set -e
[ "$rc" = 3 ] && grep -q 'RETRY A backend lanes-admission_denied' "$T/retry.out"
[ "$(jq -r .state "$T/state/stories/A.json")" = queued ]
unset CREATE_ERROR

ENQUEUE_ERROR=loop_not_running; export ENQUEUE_ERROR
set +e
"$ROOT/core/scripts/pipeline-conductor.sh" route --prd "$T/prd.json" --state "$T/state" --story A >"$T/down.out" 2>&1
rc=$?
set -e
[ "$rc" = 11 ] && grep -q 'LANE_DOWN A backend backend-dev lanes-loop_not_running' "$T/down.out"
[ "$(jq -r .state "$T/state/stories/A.json")" = queued ]
[ "$(jq -r 'has("backend-dev")' "$T/state/lanes.json")" = false ]
unset ENQUEUE_ERROR

jq '.state = "queued"' "$T/state/stories/A.json" >"$T/story.tmp" && mv "$T/story.tmp" "$T/state/stories/A.json"
: >"$FAKE_HQ_LOG"
cat >"$T/hq/core/scripts/hq-session.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *current*) printf 'test-session\n' ;; *company_slug*) : ;; esac
EOF
set +e
"$ROOT/core/scripts/pipeline-conductor.sh" route --prd "$T/prd.json" --state "$T/state" --story A >"$T/unbound.out" 2>&1
rc=$?
set -e
[ "$rc" = 1 ] && grep -q 'no company is bound' "$T/unbound.out" && [ ! -s "$FAKE_HQ_LOG" ]
cat >"$T/hq/core/scripts/hq-session.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *current*) printf 'test-session\n' ;; *company_slug*) printf 'indigo\n' ;; esac
EOF
chmod +x "$T/hq/core/scripts/hq-session.sh"
"$ROOT/core/scripts/pipeline-conductor.sh" route --prd "$T/prd.json" --state "$T/state" --story A >/dev/null
"$ROOT/core/scripts/pipeline-conductor.sh" interrupt --state "$T/state" --story A >"$T/withdrawn.out"
grep -q '^INTERRUPTED A backend withdrawn$' "$T/withdrawn.out"
jq '.state = "in_flight"' "$T/state/stories/A.json" >"$T/story.tmp" && mv "$T/story.tmp" "$T/state/stories/A.json"
INTERRUPT_MODE=already_picked_up; export INTERRUPT_MODE
"$ROOT/core/scripts/pipeline-conductor.sh" interrupt --state "$T/state" --story A >"$T/picked.out"
grep -q '^INTERRUPTED A backend picked_up$' "$T/picked.out"
unset INTERRUPT_MODE
jq '.state = "queued"' "$T/state/stories/A.json" >"$T/story.tmp" && mv "$T/story.tmp" "$T/state/stories/A.json"
ENQUEUE_ERROR=envelope_already_used; export ENQUEUE_ERROR
"$ROOT/core/scripts/pipeline-conductor.sh" route --prd "$T/prd.json" --state "$T/state" --story A >/dev/null
[ "$(jq -r '.envelope_suffixes.backend' "$T/state/stories/A.json")" = 1 ]
[ "$(jq -r .id "$FAKE_HQ_ENQUEUED/A-backend.json")" = A-backend.r1 ]
unset ENQUEUE_ERROR

for file in "$ROOT/core/scripts/pipeline-conductor.sh" "$ROOT/core/scripts/pipeline-driver.sh" \
  "$ROOT/core/scripts/pipeline-lane-rows.sh" "$ROOT/core/workers/public/dev-team/pipeline-conductor/worker.yaml" \
  "$ROOT/core/workers/public/dev-team/pipeline-conductor/skills/conduct-pipeline.md"; do
  if grep -Eq 'conduct-pool\.sh|conduct-inbox\.sh' "$file"; then echo "legacy pipeline command in $file" >&2; exit 1; fi
done
if sed -n '/^## Step 3P — Pipeline Mode/,/^## Step 4 — Parent-Driven Interactive Codex Execution/p' \
  "$ROOT/.claude/skills/run-project/SKILL.md" | grep -Eq 'conduct-pool\.sh|conduct-inbox\.sh'; then
  echo 'legacy pipeline command in run-project Step 3P' >&2; exit 1
fi

jq -n --arg line 'worker making progress' --arg pr 'https://github.com/acme/repo/pull/9' '[{lane_id:"lane-backend-dev",worker_id:"backend-dev",loop:{state:"waiting",queue_depth:0,pid:123,updated_at:"2026-10-09T08:00:00Z"},last_line:$line,pr:$pr,inbox_pending:2,elapsed_s:41}]' >"$FAKE_HQ_LIST"
jq 'del(.routed_at)' "$T/state/stories/A.json" >"$T/story.tmp" && mv "$T/story.tmp" "$T/state/stories/A.json"
"$ROOT/core/scripts/pipeline-lane-rows.sh" --state "$T/state" --session-id test-session >"$T/rows.json"
jq -e 'any(.[]; .kind == "lane" and .worker == "backend-dev" and .last_line == "worker making progress" and .pr == "https://github.com/acme/repo/pull/9" and .inbox_pending == 2 and .phase_elapsed_s == 41)' "$T/rows.json" >/dev/null

printf 'PASS: lane route reuse, retries, lane-down recovery, unbound refusal, interrupt outcomes, lane rows, and legacy-command guard\n'
