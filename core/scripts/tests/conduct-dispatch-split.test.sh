#!/usr/bin/env bash
# /conduct's light skill defers dispatch mechanics to its modules. The shared
# core holds the runner choice and the steps both runners share; the default
# dispatch.md is the subagent path; /conduct-runners holds the hq runners path.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/conduct/SKILL.md"
MODULE="$ROOT/.claude/skills/conduct/dispatch.md"
DCORE="$ROOT/.claude/skills/_shared/conduct-dispatch-core.md"
RUNNERS="$ROOT/.claude/skills/conduct-runners/dispatch.md"
CORE="$ROOT/.claude/skills/conduct/conductor-core.md"
PROTOCOL="$ROOT/.claude/skills/_shared/lane-dispatch-protocol.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
body="$(awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {fm=0; next} !fm' "$SKILL")"
[ "$(wc -l < "$SKILL" | tr -d ' ')" -le 160 ] || fail 'skill mechanics exceed 160 lines'
for h in '## Step 1: Parse the argument' '## When a task needs a worker' '## Rules'; do
  grep -qF "$h" "$SKILL" || fail "skill lost $h"
done
grep -q 'dispatch.md' "$SKILL" || fail 'skill does not load dispatch module'
grep -q 'hq runners create' "$RUNNERS" || fail 'dispatch does not create hq runners'
grep -q 'Monitor(hq runners watch' "$RUNNERS" || fail 'dispatch does not arm a lane watcher'
grep -q 'session:codex:' "$RUNNERS" || fail 'Codex completion monitor is not scoped to its parent session'
grep -q 'hq runners wait --any <lane> --for' "$RUNNERS" || fail 'Codex monitor does not wait for lane changes'
grep -q -- '--for state --for question' "$RUNNERS" || fail 'Codex monitor omits question changes'
grep -q 'since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"' "$RUNNERS" || fail 'Codex dispatch does not capture a round baseline'
grep -qF 'round_id="$(od -An -N8 -tx1 /dev/urandom | tr -d '\'' \n'\'')"' "$RUNNERS" || fail 'Codex dispatch does not create a unique round ID'
grep -qF 'round_id="$(od -An -N8 -tx1 /dev/urandom | tr -d '\'' \n'\'')"' "$PROTOCOL" || fail 'shared protocol does not create a unique round ID'
if grep -n 'uuidgen' "$DCORE" "$MODULE" "$RUNNERS" "$PROTOCOL"; then fail 'round IDs must not depend on uuidgen, which is missing on some Linux hosts'; fi
grep -qi 'one watcher per lane per round\|one Codex watcher for that lane and round' "$RUNNERS" || fail 'Codex completion watcher is not re-armed per round'
grep -Eqi 'suppress(es)? duplicates' "$RUNNERS" || fail 'Codex completion path does not suppress duplicate events'
grep -qi 'next tool call or user message' "$RUNNERS" || fail 'Codex idle-wake limitation is missing'
for pin in conduct_engine conduct_child_model conduct_child_effort; do
  grep -q "$pin" "$RUNNERS" || fail "plain /conduct does not pass the session pin $pin"
done
grep -q 'session:<session-id>' "$RUNNERS" || fail 'worker lane is missing its senior ref'
grep -q -- '--since "$since"' "$RUNNERS" || fail 'Codex watcher does not receive the captured baseline'
grep -q -- '--round-id "$round_id"' "$RUNNERS" || fail 'Codex watcher does not receive its unique round ID'
grep -q 'since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"' "$PROTOCOL" || fail 'shared protocol does not capture a round baseline'
grep -qi 'one watcher per lane.*round\|new watcher for each dispatch round' "$PROTOCOL" || fail 'shared protocol omits watcher re-arm per round'
grep -q -- '--since "$since"' "$PROTOCOL" || fail 'shared protocol does not pass the round baseline'
grep -q -- '--round-id "$round_id"' "$PROTOCOL" || fail 'shared protocol does not pass its unique round ID'
# The 2026-11 default runner is subagent (lanes on resumable subagents and
# child sessions); runner is the opt-in /conduct-runners path. 2026-10-17 still
# holds that a lane capacity refusal runs the same brief as a subagent instead
# of queuing.
grep -q '^## Runner$' "$DCORE" || fail 'dispatch lost the runner choice'
grep -q '^## Subagent dispatch$' "$MODULE" || fail 'dispatch lost subagent dispatch'
grep -q 'conduct_runner' "$DCORE" || fail 'runner session pin is missing'
grep -q '^5\. `subagent`\.$' "$DCORE" || fail 'subagent is not the default runner'
grep -q 'run_in_background: true' "$MODULE" || fail 'subagents must launch in the background'
grep -q 'refusal, including' "$RUNNERS" && grep -q 'moves the task to a subagent' "$RUNNERS" \
  || fail 'a lane capacity refusal must fall back to a subagent'
grep -q 'Never pick an account by' "$RUNNERS" || fail 'conduct must not pick an account by hand'
grep -q 'conduct_allow_extra_usage' "$RUNNERS" && grep -q -- '--allow-extra-usage' "$RUNNERS" \
  || fail 'lane extra usage must stay behind the owner opt-in'
grep -q 'outlive this session' "$RUNNERS" || fail 'session-outliving work must still use lanes'
grep -q 'envelope file named in its brief' "$DCORE" || fail 'subagent results must be verified from the envelope'
grep -q '^allowed-tools: Agent,' "$SKILL" || fail 'skill cannot call the Agent tool'
grep -q '## Step 6R: Role lanes' "$RUNNERS" || fail 'role lane behavior is missing'
grep -q 'ci-round' "$RUNNERS" || fail 'CI fix round limit is missing'
grep -q 'When `needs-qa` returns `yes`, create a `qa-tester` lane' "$RUNNERS" || fail 'UI PRs must launch the QA lane'
grep -q 'Return QA failures to the owning' "$RUNNERS" || fail 'QA failures must return to the implementation lane'
grep -q '## Step 7: End every turn with one row per running worker' "$DCORE" || fail 'live worker status rows are missing'
grep -q 'one row per running subagent' "$DCORE" || fail 'subagent status rows are missing'
for f in "$SKILL" "$MODULE" "$DCORE" "$RUNNERS" "$ROOT/.claude/skills/conduct/conductor-core.md" \
         "$ROOT/.claude/skills/_shared/lane-dispatch-protocol.md" \
         "$ROOT/.claude/skills/_shared/pool-lane-protocol.md" \
         "$ROOT/core/scripts/lanes-workers.sh"; do
  if grep -nE 'conduct-pool\.sh|conduct-inbox\.sh|conduct-link\.sh|conduct-reap\.sh|conduct-lane-status\.sh|conduct-lane-launch\.sh|conduct-lane-wait\.sh|conduct-workers\.sh|workflow-runner\.mjs' "$f"; then
    fail "legacy conduct or workflow runner reference in $f"
  fi
done
for f in "$ROOT/.claude/skills/conduct/roles"/*.md; do
  if grep -nE 'conduct-pool\.sh|conduct-inbox\.sh|conduct-link\.sh|conduct-reap\.sh|conduct-lane-status\.sh|conduct-lane-launch\.sh|conduct-lane-wait\.sh|conduct-workers\.sh' "$f"; then
    fail "legacy conduct script reference in $f"
  fi
done
grep -q 'hq runners link send' "$MODULE" || fail 'tell behavior must use lanes link send'
head -n 5 "$MODULE" | grep >/dev/null '_shared/conduct-dispatch-core.md' || fail 'default dispatch does not load the shared core first'
head -n 5 "$RUNNERS" | grep >/dev/null '_shared/conduct-dispatch-core.md' || fail 'runners dispatch does not load the shared core first'
grep -q 'hq runners link close' "$SKILL" || fail 'close behavior must use lanes link close'
grep -q 'conduct.default_enabled' "$CORE" || fail 'conductor core lost the default mode context'
grep -q '<!-- inject:start -->' "$CORE" && grep -q '<!-- inject:end -->' "$CORE" || fail 'inject markers are missing'
injected="$(awk '/<!-- inject:start -->/{on=1;next} /<!-- inject:end -->/{on=0} on' "$CORE")"
grep -q 'Conduct mode is on (conduct.default_enabled)' <<<"$injected" || fail 'conductor core does not identify the active conduct mode'
grep -q 'engine is chosen at first dispatch' <<<"$injected" || fail 'conductor core lost the first-dispatch engine contract'
for mapping in 'backend.*backend-dev' 'frontend.*frontend-dev' 'designer.*paper-designer' 'qa.*qa-tester' 'orchestrator.*architect'; do
  grep -Eq "$mapping" "$DCORE" || fail "role mapping is missing: $mapping"
done
# feedback_fa7ed7fb: children must not hand back while their own background
# reviewers still run, so the conductor never has to chase a final read.
grep -q 'wait for every background reviewer or subagent' "$MODULE" || fail 'dispatch prompt lets a child finish with background reviewers still running'
for f in "$ROOT/.claude/skills/conduct/roles"/*.md; do
  grep -q 'never hand back while a child is still running' "$f" || fail "role $f lets a child hand back with background reviewers still running"
done
echo 'conduct-dispatch-split.test.sh: split dispatch contract passed'
