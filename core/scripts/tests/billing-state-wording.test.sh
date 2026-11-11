#!/usr/bin/env bash
# billing-state-wording.test.sh - the setup worker's pricing skill and /hq-cost
# carry the same billing-state rule (usage-billing-next US-031, criterion 12):
# say the state once, give the one action, and never add a card, open a
# checkout for the person, or change a spend limit.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PRICING="$ROOT/core/workers/public/setup/skills/pricing.md"
COST="$ROOT/.claude/skills/hq-cost/SKILL.md"

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok - $1"; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

echo "billing-state wording"
for f in "$PRICING" "$COST"; do
  [ -f "$f" ] || fail "missing $f"
  rel="${f#"$ROOT"/}"
  flat "$f" > "$TMPD/flat.txt"
  grep -q 'say it once' "$TMPD/flat.txt" || fail "$rel must say to state the billing state once"
  grep -q 'the Billing page in the HQ desktop app, or the exact command HQ named' "$TMPD/flat.txt" \
    || fail "$rel must name the one action"
  grep -q 'Never add a card, open a checkout for the person, or change a spend limit' "$TMPD/flat.txt" \
    || fail "$rel must forbid adding a card, opening a checkout or changing a limit"
  ok "$rel carries the rule"
done

for f in "$PRICING" "$COST"; do
  rel="${f#"$ROOT"/}"
  flat "$f" > "$TMPD/flat.txt"
  grep -q 'If a command quotes a price, refuses something or returns an upgrade link, tell the person exactly that, in plain words, with the link' "$TMPD/flat.txt" \
    || fail "$rel must still pass on what HQ returns (price, refusal, upgrade link)"
  ok "$rel passes on what HQ returns"
done

echo "billing-state-wording: $PASS checks passed"
