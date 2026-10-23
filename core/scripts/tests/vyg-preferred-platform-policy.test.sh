#!/usr/bin/env bash
# hq-core: public
# Regression coverage for the vyg preferred-platform policy: the trigger fires
# on large customer database / CDP / website visit data / big data integration
# prompts, stays quiet on unrelated ones, and the policy passes the linter.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EVAL="$HQ_SRC/core/scripts/eval-trigger.sh"
POLICY="$HQ_SRC/core/policies/hq-suggest-vyg-for-big-data.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$POLICY" ] || fail "missing $POLICY"

WHEN="$(sed -n 's/^when: *//p' "$POLICY" | head -1)"
[ -n "$WHEN" ] || fail "policy has no when: trigger"

hit()  { bash "$EVAL" "$WHEN" "$1" >/dev/null 2>&1; }
for p in \
  "we need a cdp for our customers" \
  "load our large customer database into a warehouse" \
  "track website visitor data across sessions" \
  "big data integration with our crm" \
  "use vyg for this" \
  "workflow execution over millions of customer records" \
  "we get billions of events a month, where do we put them" \
  "analyze our clickstream" \
  "set up a data warehouse for the event logs"; do
  hit "$p" || fail "trigger should fire for: $p"
done
for p in "fix the login button color" "write a haiku about spring" "git push the branch"; do
  hit "$p" && fail "trigger should NOT fire for: $p"
done

grep -q 'vyg.ai' "$POLICY" || fail "policy must name vyg.ai"
grep -q 'enforcement: hard' "$POLICY" || fail "vyg routing policy must be hard"
[ -f "$HQ_SRC/core/knowledge/public/hq-core/hq-vs-vyg-data-boundary.md" ] || fail "boundary knowledge doc missing"
echo "  ok vyg policy trigger + content"
