#!/usr/bin/env bash
# /overnight conduct mode names a routing path /conduct actually has
# (PR #1720 review): a /conduct conductor with a lanes link (after
# /conduct adopt) routes through `hq lanes link send`, the command
# /conduct tell uses; with no link its children are worker lanes, listed by
# `hq lanes list --json` and `conduct-standing.sh list` and messaged with
# `hq lanes message`. The skill must not forbid the command /conduct uses.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ON="$ROOT/.claude/skills/overnight/SKILL.md"
CONDUCT="$ROOT/.claude/skills/conduct/SKILL.md"
DISPATCH="$ROOT/.claude/skills/conduct/dispatch.md"
STANDING="$ROOT/core/scripts/conduct-standing.sh"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

if grep -Fq 'never `hq lanes link send`' "$ON"; then
  bad "overnight forbids hq lanes link send, which /conduct tell uses"
fi
grep -Fq 'hq lanes link send --link <link-id> --child' "$CONDUCT" \
  || bad "conduct no longer documents hq lanes link send; update overnight to match"
grep -Fq '/conduct adopt' "$ON" || bad "overnight must say when a /conduct conductor has a link (/conduct adopt)"
grep -Fq 'hq lanes list --json' "$ON" || bad "conduct mode must name hq lanes list --json as a child source"
grep -Fq 'conduct-standing.sh list' "$ON" || bad "conduct mode must name conduct-standing.sh list as a child source"
grep -Eq '^[#[:space:]]*bash core/scripts/conduct-standing.sh list' "$STANDING" \
  || bad "conduct-standing.sh has no list subcommand"
grep -Fq 'hq lanes message <lane> --text' "$ON" || bad "conduct mode must route with hq lanes message"
grep -Fq 'hq lanes message <lane> --text' "$DISPATCH" || bad "dispatch.md no longer documents hq lanes message"
row="$(grep -F '| (b) Work request owned by a child |' "$ON")"
grep -Fq 'Step 2 child list' <<< "$row" || bad "Step 4 (b) needs the conduct-mode child-list source"

[ "$fail" -eq 0 ] || exit 1
echo "overnight conduct mode: ok"
