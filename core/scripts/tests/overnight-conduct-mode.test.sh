#!/usr/bin/env bash
# /overnight conduct mode names a routing path /conduct actually has
# (PR #1720 review): a /conduct conductor with a lanes link (after
# /conduct adopt) routes through `hq runners link send`, the command
# /conduct tell uses; with no link its children are worker lanes, listed by
# `hq runners list --json` and `conduct-standing.sh list` and messaged with
# `hq runners message`. The skill must not forbid the command /conduct uses.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ON="$ROOT/.claude/skills/overnight/SKILL.md"
CONDUCT="$ROOT/.claude/skills/conduct/SKILL.md"
DISPATCH="$ROOT/.claude/skills/conduct-runners/dispatch.md"
STANDING="$ROOT/core/scripts/conduct-standing.sh"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

if grep -Fq 'never `hq runners link send`' "$ON"; then
  bad "overnight forbids hq runners link send, which /conduct tell uses"
fi
grep -Fq 'hq runners link send --link <link-id> --child' "$CONDUCT" \
  || bad "conduct no longer documents hq runners link send; update overnight to match"
grep -Fq '/conduct adopt' "$ON" || bad "overnight must say when a /conduct conductor has a link (/conduct adopt)"
grep -Fq 'hq runners list --json' "$ON" || bad "conduct mode must name hq runners list --json as a child source"
grep -Fq 'conduct-standing.sh list' "$ON" || bad "conduct mode must name conduct-standing.sh list as a child source"
grep -Eq '^[#[:space:]]*bash core/scripts/conduct-standing.sh list' "$STANDING" \
  || bad "conduct-standing.sh has no list subcommand"
grep -Fq 'hq runners message <lane> --text' "$ON" || bad "conduct mode must route with hq runners message"
grep -Fq 'hq runners message <lane> --text' "$DISPATCH" || bad "dispatch.md no longer documents hq runners message"
row="$(grep -F '| (b) Work request owned by a child |' "$ON")"
grep -Fq 'Step 2 child list' <<< "$row" || bad "Step 4 (b) needs the conduct-mode child-list source"

[ "$fail" -eq 0 ] || exit 1
echo "overnight conduct mode: ok"
