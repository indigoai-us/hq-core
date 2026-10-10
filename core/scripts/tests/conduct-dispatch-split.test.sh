#!/usr/bin/env bash
# /conduct's light skill defers lane mechanics until dispatch, using hq lanes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/conduct/SKILL.md"
MODULE="$ROOT/.claude/skills/conduct/dispatch.md"
CORE="$ROOT/.claude/skills/conduct/conductor-core.md"
PROTOCOL="$ROOT/.claude/skills/_shared/lane-dispatch-protocol.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
body="$(awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {fm=0; next} !fm' "$SKILL")"
[ "$(wc -l < "$SKILL" | tr -d ' ')" -le 160 ] || fail 'skill mechanics exceed 160 lines'
for h in '## Step 1: Parse the argument' '## When a task needs a lane' '## Rules'; do
  grep -qF "$h" "$SKILL" || fail "skill lost $h"
done
grep -q 'dispatch.md' "$SKILL" || fail 'skill does not load dispatch module'
grep -q 'hq lanes create' "$MODULE" || fail 'dispatch does not create hq lanes'
grep -q 'Monitor(hq lanes watch' "$MODULE" || fail 'dispatch does not arm a lane watcher'
grep -q 'session:codex:' "$MODULE" || fail 'Codex completion monitor is not scoped to its parent session'
grep -q 'hq lanes wait --any <lane> --for' "$MODULE" || fail 'Codex monitor does not wait for lane changes'
grep -q -- '--for state --for question' "$MODULE" || fail 'Codex monitor omits question changes'
grep -q 'since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"' "$MODULE" || fail 'Codex dispatch does not capture a round baseline'
grep -qF 'round_id="$(od -An -N8 -tx1 /dev/urandom | tr -d '\'' \n'\'')"' "$MODULE" || fail 'Codex dispatch does not create a unique round ID'
grep -qF 'round_id="$(od -An -N8 -tx1 /dev/urandom | tr -d '\'' \n'\'')"' "$PROTOCOL" || fail 'shared protocol does not create a unique round ID'
if grep -n 'uuidgen' "$MODULE" "$PROTOCOL"; then fail 'round IDs must not depend on uuidgen, which is missing on some Linux hosts'; fi
grep -qi 'one watcher per lane per round\|one Codex watcher for that lane and round' "$MODULE" || fail 'Codex completion watcher is not re-armed per round'
grep -Eqi 'suppress(es)? duplicates' "$MODULE" || fail 'Codex completion path does not suppress duplicate events'
grep -qi 'next tool call or user message' "$MODULE" || fail 'Codex idle-wake limitation is missing'
for pin in conduct_engine conduct_child_model conduct_child_effort; do
  grep -q "$pin" "$MODULE" || fail "plain /conduct does not pass the session pin $pin"
done
grep -q 'session:<session-id>' "$MODULE" || fail 'worker lane is missing its senior ref'
grep -q -- '--since "$since"' "$MODULE" || fail 'Codex watcher does not receive the captured baseline'
grep -q -- '--round-id "$round_id"' "$MODULE" || fail 'Codex watcher does not receive its unique round ID'
grep -q 'since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"' "$PROTOCOL" || fail 'shared protocol does not capture a round baseline'
grep -qi 'one watcher per lane.*round\|new watcher for each dispatch round' "$PROTOCOL" || fail 'shared protocol omits watcher re-arm per round'
grep -q -- '--since "$since"' "$PROTOCOL" || fail 'shared protocol does not pass the round baseline'
grep -q -- '--round-id "$round_id"' "$PROTOCOL" || fail 'shared protocol does not pass its unique round ID'
grep -q 'Admission and capacity refusals keep the task' "$MODULE" || fail 'admission refusal must remain queued'
grep -q '## Step 6R: Role lanes' "$MODULE" || fail 'role lane behavior is missing'
grep -q 'ci-round' "$MODULE" || fail 'CI fix round limit is missing'
grep -q 'When `needs-qa` returns `yes`, create a `qa-tester` lane' "$MODULE" || fail 'UI PRs must launch the QA lane'
grep -q 'Return QA failures to the owning' "$MODULE" || fail 'QA failures must return to the implementation lane'
grep -q '## Step 7: End every turn with one row per running lane' "$MODULE" || fail 'live lane status rows are missing'
for f in "$SKILL" "$MODULE" "$ROOT/.claude/skills/conduct/conductor-core.md" \
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
grep -q 'hq lanes link send' "$MODULE" || fail 'tell behavior must use lanes link send'
grep -q 'hq lanes link close' "$SKILL" || fail 'close behavior must use lanes link close'
grep -q 'conduct.default_enabled' "$CORE" || fail 'conductor core lost the default mode context'
grep -q '<!-- inject:start -->' "$CORE" && grep -q '<!-- inject:end -->' "$CORE" || fail 'inject markers are missing'
injected="$(awk '/<!-- inject:start -->/{on=1;next} /<!-- inject:end -->/{on=0} on' "$CORE")"
grep -q 'Conduct mode is on (conduct.default_enabled)' <<<"$injected" || fail 'conductor core does not identify the active conduct mode'
grep -q 'engine is chosen at first dispatch' <<<"$injected" || fail 'conductor core lost the first-dispatch engine contract'
for mapping in 'backend.*backend-dev' 'frontend.*frontend-dev' 'designer.*paper-designer' 'qa.*qa-tester' 'orchestrator.*architect'; do
  grep -Eq "$mapping" "$MODULE" || fail "role mapping is missing: $mapping"
done
echo 'conduct-dispatch-split.test.sh: lane-native dispatch contract passed'
