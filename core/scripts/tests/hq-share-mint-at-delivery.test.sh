#!/usr/bin/env bash
# hq-core: public
# hq-share-mint-at-delivery.test.sh -- /hq-share mints its 15-minute
# share-session link as the last step before delivery and re-mints a link that
# is near expiry or was delayed (compaction, questions, later turns), instead of
# handing the user an expired link. Feedback 1c1608cb-4eb0-44cf-9891-a033e732e797.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/hq-share/SKILL.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qF -- "$1" "$SKILL" || fail "$2"; }
[ -f "$SKILL" ] || fail "missing $SKILL"

has '**Mint at delivery.**' "Step 4 must say to mint at delivery"
grep -q 'final tool call of the turn' "$SKILL" || fail "mint must be the final tool call of the turn"
has '### 4a. Re-mint instead of delivering a stale link' "Step 4a re-mint section missing"
has 'fewer than 5 minutes remain, or the link has already expired' "re-mint threshold missing"
has 'a compaction or a resumed session' "re-mint after compaction missing"
has 'asks for the link again in a later turn' "re-mint on later-turn request missing"
has 'Show only the newest link.' "only the newest link may be shown"

# Ordering: the drafting step and its picker come before the mint, and Step 4a
# sits between the mint and delivery.
line() { grep -nF -- "$1" "$SKILL" | head -1 | cut -d: -f1; }
d="$(line '### 3.5. Draft the note')"; m="$(line '### 4. Mint + open')"
r="$(line '### 4a. Re-mint')"; v="$(line '### 5. Surface the URL')"
[ -n "$d" ] && [ -n "$m" ] && [ -n "$r" ] && [ -n "$v" ] || fail "section headings missing"
[ "$d" -lt "$m" ] && [ "$m" -lt "$r" ] && [ "$r" -lt "$v" ] || fail "section order must be 3.5 < 4 < 4a < 5"

# The stale TTL bound is gone; the CLI caps --expires at 24h.
grep -qF 'bounded `60s..7d`' "$SKILL" && fail "stale 60s..7d TTL bound still documented"
echo "hq-share-mint-at-delivery: all checks passed"
