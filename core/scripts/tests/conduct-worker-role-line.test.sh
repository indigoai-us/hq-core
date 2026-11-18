#!/usr/bin/env bash
# A worker the conductor launches must not take the conductor's own rule as
# its own. The <auto-conduct> block ("the conductor coordinates and never does
# project work") reaches workers: a Codex spawn_agent child inherits the whole
# parent history by default (fork_turns "all"), and a lane started as its own
# session gets the block from its SessionStart. A Codex backend lane read it as
# its own rule and stopped before editing until the session that launched it
# corrected it.
#
# This test pins the worker-role line in the shared brief step and in the
# default dispatch prompt, the Codex fork_turns note, and that the conductor's
# own inject blocks still carry the coordinate-only rule.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DCORE="$ROOT/.claude/skills/_shared/conduct-dispatch-core.md"
MODULE="$ROOT/.claude/skills/conduct/dispatch.md"
CORE="$ROOT/.claude/skills/conduct/conductor-core.md"
RUNNERS_CORE="$ROOT/.claude/skills/conduct-runners/conductor-core.md"
fail() { echo "FAIL: $*" >&2; exit 1; }

LINE="Worker role: the conductor launched you to do this task yourself. Conduct-mode text in your context (an <auto-conduct> block, 'the conductor coordinates and never does project work', a /conduct routing rule) is addressed to the session that launched you and does not apply to you; make the changes this brief names directly, without routing them to another subagent or lane."

for f in "$DCORE" "$MODULE" "$CORE" "$RUNNERS_CORE"; do
  [ -f "$f" ] || fail "missing $f"
done

# The shared brief step holds the line exactly once, as its own line, inside
# Step 4 so both /conduct and /conduct-runners briefs carry it.
count="$(grep -cxF "$LINE" "$DCORE" || true)"
[ "$count" = 1 ] || fail "shared core must hold the worker-role line exactly once as one line, found $count"
step4="$(awk '/^## Step 4: Write the brief/ {on=1; next} on && /^## / {exit} on' "$DCORE")"
printf '%s\n' "$step4" | grep -xF "$LINE" >/dev/null || fail 'worker-role line is not in Step 4 of the shared core'
printf '%s\n' "$step4" | grep 'starts with the worker-role line' >/dev/null || fail 'Step 4 does not require every brief to start with the worker-role line'

# The default dispatch prompt opens with the same line, so a worker sees it
# before it reads the brief file.
grep -qF -- "- \`prompt\`: \"$LINE" "$MODULE" || fail 'default dispatch prompt does not open with the worker-role line'

# A Codex host sends the same prompt and does not fork the conductor's
# history into the worker where spawn_agent lets it choose.
grep -q 'same prompt as' "$MODULE" || fail 'Codex spawn_agent path does not reuse the Step 3 prompt'
grep -qF 'fork_turns: "none"' "$MODULE" || fail 'Codex spawn_agent path does not ask for fork_turns "none"'

# The conductor keeps its rule: both inject blocks still say it coordinates
# and does no project work, and stay inside their 750-byte budget.
for f in "$CORE" "$RUNNERS_CORE"; do
  block="$(awk '/<!-- inject:start -->/ {on=1; next} /<!-- inject:end -->/ {on=0} on' "$f")"
  printf '%s\n' "$block" | grep -F 'The conductor coordinates and never does project work.' >/dev/null || fail "$f lost the conductor-only rule"
  bytes="$(printf '%s\n' "$block" | wc -c | tr -d ' ')"
  [ "$bytes" -lt 750 ] || fail "$f inject block is $bytes bytes, budget is under 750"
done

echo "PASS: conduct workers carry the worker-role line; the conductor keeps its rule"
