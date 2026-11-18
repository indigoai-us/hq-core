#!/usr/bin/env bash
# conduct-dispatch-headings.test.sh — the conduct dispatch module is split into a
# shared core, the default subagent file, and the /conduct-runners file. Every
# level-2 and level-3 heading of the pre-split dispatch.md lands in exactly one
# of the three, and the default file names no `hq runners` command except
# `hq runners link`.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

DCORE="$ROOT/.claude/skills/_shared/conduct-dispatch-core.md"
MODULE="$ROOT/.claude/skills/conduct/dispatch.md"
RUNNERS="$ROOT/.claude/skills/conduct-runners/dispatch.md"
for f in "$DCORE" "$MODULE" "$RUNNERS"; do
  [ -f "$f" ] || fail "missing ${f#"$ROOT"/}"
done

echo "every pre-split heading lands exactly once"
while IFS= read -r heading; do
  [ -n "$heading" ] || continue
  n="$(cat "$DCORE" "$MODULE" "$RUNNERS" | grep -Fxc -- "$heading" || true)"
  [ "$n" = 1 ] || fail "heading '$heading' appears $n times across the three files (expected 1)"
done <<'HEADINGS'
## Runner
## Standing worker lanes
## Subagent dispatch
## Engine roster
## How work leaves this session
## Signed-out accounts: one owner card per account
### The dedupe file
### Raising the card
### Answers
### Worked example
## Step 2: Choose the worker
## Step 3: Assign a pool slot
## Step 4: Write the brief
## Step 5: Launch the lane, detached
### Tell and close linked sessions
## Step 5b: Send a message to a lane that is already running
## Step 6: Read the outcome, then verify it
## Step 6R: Role lanes (`/conduct --workers`)
## Step 7: End every turn with one row per running worker
## Testing capacity distribution locally
## Dry run: signed-out card
HEADINGS

echo "the default file names only hq runners link"
other="$(grep -E 'hq (runners|lanes)' "$MODULE" | grep -v 'hq runners link' || true)"
[ -z "$other" ] || fail "conduct/dispatch.md names hq runners commands other than hq runners link: $other"
grep -q 'hq runners link send' "$MODULE" || fail 'conduct/dispatch.md lost hq runners link send'
grep -q 'hq runners link close' "$MODULE" || fail 'conduct/dispatch.md lost hq runners link close'

echo "both mode files point at the shared core first"
for f in "$MODULE" "$RUNNERS"; do
  head -n 5 "$f" | grep >/dev/null '_shared/conduct-dispatch-core.md' \
    || fail "${f#"$ROOT"/} does not name _shared/conduct-dispatch-core.md in its first 5 lines"
done

echo "lane sections live in the runners file"
for heading in '## Standing worker lanes' '## Step 3: Assign a pool slot' \
  '## Step 5: Launch the lane, detached' '## Step 5b: Send a message to a lane that is already running' \
  '## Step 6R: Role lanes (`/conduct --workers`)' '## Signed-out accounts: one owner card per account'; do
  grep -Fxq -- "$heading" "$RUNNERS" || fail "'$heading' is not in conduct-runners/dispatch.md"
done

echo 'conduct-dispatch-headings.test.sh: every heading lands once and the default file is subagent-only'
