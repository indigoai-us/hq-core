#!/usr/bin/env bash
# Shared orchestrator skills dispatch through hq lanes after CL-6 migrations.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILLS="${HQ_ORCH_SKILLS_DIR:-$ROOT/.claude/skills}"
CONDUCT="$SKILLS/conduct/dispatch.md"
EXEC_TASK="$SKILLS/execute-task/SKILL.md"
RUN_PROJECT="$SKILLS/run-project/SKILL.md"
DISPATCH="$SKILLS/_shared/lane-dispatch-protocol.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
for f in "$CONDUCT" "$EXEC_TASK" "$RUN_PROJECT" "$DISPATCH"; do [ -f "$f" ] || fail "missing $f"; done

for skill in "$CONDUCT" "$EXEC_TASK" "$RUN_PROJECT"; do
  grep -q 'hq lanes create' "$skill" || fail "$(basename "$skill") does not create lanes"
  grep -q 'session:' "$skill" || fail "$(basename "$skill") does not assign the caller as senior"
done
sed -n '1,/^## Step 3P /p' "$RUN_PROJECT" > "${TMPDIR:-/tmp}/cl6c-run-project-interactive.md"
RUN_INTERACTIVE="${TMPDIR:-/tmp}/cl6c-run-project-interactive.md"
for legacy in conduct-pool.sh conduct-inbox.sh conduct-link.sh conduct-reap.sh conduct-lane-status.sh conduct-lane-launch.sh conduct-lane-wait.sh conduct-workers.sh workflow-runner.mjs; do
  if grep -n "$legacy" "$CONDUCT" "$DISPATCH"; then fail "legacy conduct dispatch reference remains: $legacy"; fi
done
rm -f "$RUN_INTERACTIVE"

# Plain /conduct pins apply to every lane, independently of --workers mode.
for key in conduct_engine conduct_child_model conduct_child_effort; do grep -q "$key" "$CONDUCT" || fail "conduct omits $key"; done
grep -qi 'A user flag overrides' "$CONDUCT" || fail 'conduct does not describe user flag precedence'
grep -q 'hq lanes message' "$CONDUCT" || fail 'conduct follow-up path missing'
grep -q 'hq lanes list --json' "$CONDUCT" || fail 'conduct lane status path missing'
grep -q 'session:codex:' "$CONDUCT" || fail 'Codex parent monitor is not scoped to its session'
grep -q 'hq lanes wait --any <lane> --for envelope --for state' "$CONDUCT" || fail 'Codex monitor does not wait for lane completion'
grep -qi 'suppresses duplicates' "$CONDUCT" || fail 'Codex completion event is not deduplicated'
grep -qi 'next tool call or user message' "$CONDUCT" || fail 'Codex idle wake limitation is missing'

# Shared lane contract remains source of truth for every skill.
grep -q 'hq lanes create' "$DISPATCH" || fail 'shared protocol omits create'
grep -q 'conduct_child_model' "$DISPATCH" || fail 'shared protocol omits session model pins'
grep -q 'Monitor(hq lanes watch' "$DISPATCH" || fail 'Claude lane monitor path missing'

# Keep CL-6a pipeline assertions in the merged shared test.
awk '/^## Step 3P /{on=1} /^## Step 4 /{on=0} on' "$RUN_PROJECT" > "${TMPDIR:-/tmp}/cl6c-pipeline-test.md"
PIPE="${TMPDIR:-/tmp}/cl6c-pipeline-test.md"
grep -q 'hq lanes create --loop' "$PIPE" || fail 'pipeline loop lanes are missing'
grep -q 'hq lanes enqueue' "$PIPE" || fail 'pipeline enqueue path is missing'
grep -q 'capacity' "$PIPE" || fail 'pipeline lane capacity handling is missing'
grep -q 'hq lanes list --json' "$PIPE" || fail 'pipeline recovery does not list lanes'
rm -f "$PIPE"
echo 'orchestrator-skills-dispatch-lanes.test.sh: shared lane dispatch contract passed'
