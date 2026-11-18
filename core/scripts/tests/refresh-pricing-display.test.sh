#!/usr/bin/env bash
# refresh-pricing.sh renders a non-empty string displayText as the meter price.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT_SRC="$ROOT/core/scripts/refresh-pricing.sh"
FIXTURE="$ROOT/core/scripts/tests/fixtures/pricing-feed-display-per-100.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
pass=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else echo "FAIL $1 (expected $2, got $3)"; fail=1; fi; }

if grep -F '$0.10 per 100' "$SCRIPT_SRC" >/dev/null; then
  echo "FAIL renderer source contains \$0.10 per 100"
  fail=1
else
  ok 'renderer source has no $0.10 per 100'
fi

BASE="$TMP/r"
mkdir -p "$BASE/core/scripts" "$BASE/core/knowledge/public/hq-core" "$BASE/core/workers/public/setup/skills"
cp "$SCRIPT_SRC" "$BASE/core/scripts/refresh-pricing.sh"
cp "$ROOT/core/knowledge/public/hq-core/pricing-and-billing.md" "$BASE/core/knowledge/public/hq-core/"
cp "$ROOT/core/knowledge/public/hq-core/plans-and-pricing.md" "$BASE/core/knowledge/public/hq-core/"
cp "$ROOT/core/workers/public/setup/skills/pricing.md" "$BASE/core/workers/public/setup/skills/"
SCRIPT="$BASE/core/scripts/refresh-pricing.sh"
MD="$BASE/core/knowledge/public/hq-core/pricing-and-billing.md"
PLANS="$BASE/core/knowledge/public/hq-core/plans-and-pricing.md"
SKILL="$BASE/core/workers/public/setup/skills/pricing.md"
JSON="$BASE/core/knowledge/public/hq-core/pricing.json"
cp "$MD" "$TMP/md.orig"
cp "$PLANS" "$TMP/plans.orig"
cp "$SKILL" "$TMP/skill.orig"

outside() {
  awk -v start="$2" -v end="$3" '
    $0 == start { print; skip = 1; next }
    $0 == end { skip = 0 }
    !skip { print }
  ' "$1"
}
cmp_outside() {
  outside "$1" "$3" "$4" >"$TMP/out-a"
  outside "$2" "$3" "$4" >"$TMP/out-b"
  if cmp -s "$TMP/out-a" "$TMP/out-b"; then
    ok "$5"
  else
    echo "FAIL $5"
    diff -u "$TMP/out-a" "$TMP/out-b" | head -40
    fail=1
  fi
}
exact() {
  grep -F -x -e "$2" -- "$3" >/dev/null
  check "$1" 0 $?
}
no_old_price() {
  case "$2" in
    *'$0.05'*|*'$0.001'*) echo "FAIL $1 still has an old unit price: $2"; fail=1 ;;
    *) ok "$1 has no \$0.05 or \$0.001" ;;
  esac
}

bash "$SCRIPT" --from-file "$FIXTURE" >/dev/null 2>"$TMP/refresh.err"
check "refresh exits 0" 0 $?
if [ "$fail" -ne 0 ]; then cat "$TMP/refresh.err" >&2; fi

NUM_START='<!-- pricing:numbers:start -->'
NUM_END='<!-- pricing:numbers:end -->'
METER_START='<!-- pricing:meters:start -->'
METER_END='<!-- pricing:meters:end -->'
cmp_outside "$TMP/md.orig" "$MD" "$NUM_START" "$NUM_END" "billing text outside numbers markers is unchanged"
cmp_outside "$TMP/plans.orig" "$PLANS" "$METER_START" "$METER_END" "plans text outside meters markers is unchanged"
cmp_outside "$TMP/skill.orig" "$SKILL" "$METER_START" "$METER_END" "skill text outside meters markers is unchanged"

exact "billing heading names the 2026-11-13 card version" '### Usage card (new signups from 2026-10-16, card version 2026-11-13)' "$MD"
exact "billing gateway uses displayText" '| Gateway call | $0.10 per 100 calls | call | no |' "$MD"
exact "billing HQ MCP uses displayText" '| HQ MCP call | $0.10 per 100 calls | call | no |' "$MD"
exact "plans gateway uses displayText" '| Gateway call (integrations and external MCP through HQ) | $0.10 per 100 calls |' "$PLANS"
exact "plans HQ MCP uses displayText" '| HQ MCP call | $0.10 per 100 calls |' "$PLANS"
exact "skill connected-app uses displayText" '- a call to a connected app or an outside MCP server through HQ: $0.10 per 100 calls' "$SKILL"
exact "skill HQ MCP uses displayText" '- an HQ MCP call: $0.10 per 100 calls' "$SKILL"

no_old_price "billing gateway line" "$(grep -F '| Gateway call |' "$MD")"
no_old_price "billing HQ MCP line" "$(grep -F '| HQ MCP call |' "$MD")"
no_old_price "plans gateway line" "$(grep -F '| Gateway call (' "$PLANS")"
no_old_price "plans HQ MCP line" "$(grep -F '| HQ MCP call |' "$PLANS")"
no_old_price "skill connected-app line" "$(grep -F -- '- a call to a connected app' "$SKILL")"
no_old_price "skill HQ MCP line" "$(grep -F -- '- an HQ MCP call:' "$SKILL")"

exact "billing sync line unchanged" '| Sync | $0.10 | sync | no |' "$MD"
exact "billing agent run unchanged" '| Agent run | $0.05 | run | no |' "$MD"
exact "billing storage unchanged" '| Storage | $2.00 | GB-month | no |' "$MD"
exact "billing secret unchanged" '| Secret | $0.50 | secret-month | no |' "$MD"
exact "billing vault unchanged" '| Vault | $5.00 | vault-month | yes |' "$MD"
exact "billing meeting hours unchanged" '| Meeting hours | $1.00 | hour | no |' "$MD"
exact "plans sync unchanged" '| Sync (moved files, per leg) | $0.10 |' "$PLANS"
exact "plans agent run unchanged" '| Agent run | $0.05 |' "$PLANS"
exact "plans storage unchanged" '| Storage | $2.00 per GB-month |' "$PLANS"
exact "plans secret unchanged" '| Secret | $0.50 per secret-month |' "$PLANS"
exact "plans vault unchanged" '| Vault | $5 per vault per month, for each company vault and each personal vault; waived during the trial |' "$PLANS"
exact "plans adds meeting hours with its unit" '| Meeting hours | $1.00 per hour |' "$PLANS"
exact "skill sync unchanged" '- sync: $0.10 per moved file, per leg' "$SKILL"
exact "skill agent run unchanged" '- an agent run: $0.05' "$SKILL"
exact "skill files unchanged" '- files: $2.00 per GB a month' "$SKILL"
exact "skill keys unchanged" '- keys: $0.50 per key a month' "$SKILL"
exact "skill vault price unchanged" '- each company vault and each personal vault: $5 a month (part of the $10' "$SKILL"
exact "skill vault continuation unchanged" '  included usage; free during the trial)' "$SKILL"
exact "skill adds meeting hours with its unit" '- a meeting hour: $1.00 an hour' "$SKILL"

cmp -s "$JSON" "$FIXTURE"
check "pricing.json is a verbatim copy of the fixture" 0 $?

cp "$MD" "$TMP/md1"
cp "$PLANS" "$TMP/plans1"
cp "$SKILL" "$TMP/skill1"
cp "$JSON" "$TMP/json1"
bash "$SCRIPT" --from-file "$FIXTURE" >/dev/null 2>&1
check "second refresh exits 0" 0 $?
cmp -s "$MD" "$TMP/md1"; check "second run billing is byte-identical" 0 $?
cmp -s "$PLANS" "$TMP/plans1"; check "second run plans is byte-identical" 0 $?
cmp -s "$SKILL" "$TMP/skill1"; check "second run skill is byte-identical" 0 $?
cmp -s "$JSON" "$TMP/json1"; check "second run pricing.json is byte-identical" 0 $?

jq '(.usage.meters[] | select(.id == "integration-call") | .displayText) = 100' "$FIXTURE" >"$TMP/num.json"
bash "$SCRIPT" --from-file "$TMP/num.json" >/dev/null 2>&1
check "wrong-type displayText refresh exits 0" 0 $?
exact "billing gateway falls back to tenth-of-a-cent" '| Gateway call | $0.001 | call | no |' "$MD"
exact "plans gateway falls back to tenth-of-a-cent" '| Gateway call (integrations and external MCP through HQ) | $0.001 |' "$PLANS"
exact "skill gateway falls back to tenth-of-a-cent" '- a call to a connected app or an outside MCP server through HQ: $0.001' "$SKILL"
not_zero() {
  printf '%s\n' "$2" | grep -Eq '\$0\.00([^0-9]|$)'
  check "$1 does not match \$0.00" 1 $?
}
not_zero "billing gateway fallback" "$(grep -F '| Gateway call |' "$MD")"
not_zero "plans gateway fallback" "$(grep -F '| Gateway call (' "$PLANS")"
not_zero "skill gateway fallback" "$(grep -F -- '- a call to a connected app' "$SKILL")"

cp "$SKILL" "$TMP/skill-good.md"
grep -v '^<!-- pricing:meters:end -->$' "$SKILL" >"$TMP/skill-broken.md"
cp "$TMP/skill-broken.md" "$SKILL"
cp "$MD" "$TMP/snap-md"
cp "$PLANS" "$TMP/snap-plans"
cp "$SKILL" "$TMP/snap-skill"
cp "$JSON" "$TMP/snap-json"
bash "$SCRIPT" --from-file "$FIXTURE" >/dev/null 2>&1
check "missing skill end marker exits 3" 3 $?
cmp -s "$MD" "$TMP/snap-md"; check "missing skill marker leaves billing unchanged" 0 $?
cmp -s "$PLANS" "$TMP/snap-plans"; check "missing skill marker leaves plans unchanged" 0 $?
cmp -s "$SKILL" "$TMP/snap-skill"; check "missing skill marker leaves skill unchanged" 0 $?
cmp -s "$JSON" "$TMP/snap-json"; check "missing skill marker leaves pricing.json unchanged" 0 $?

cp "$TMP/skill-good.md" "$SKILL"
grep -v '^<!-- pricing:meters:start -->$' "$PLANS" | grep -v '^<!-- pricing:meters:end -->$' >"$TMP/plans-broken.md"
cp "$TMP/plans-broken.md" "$PLANS"
cp "$MD" "$TMP/snap-md"
cp "$PLANS" "$TMP/snap-plans"
cp "$SKILL" "$TMP/snap-skill"
cp "$JSON" "$TMP/snap-json"
bash "$SCRIPT" --from-file "$FIXTURE" >/dev/null 2>&1
check "plans file with no marker pair exits 3" 3 $?
cmp -s "$MD" "$TMP/snap-md"; check "missing plans markers leaves billing unchanged" 0 $?
cmp -s "$PLANS" "$TMP/snap-plans"; check "missing plans markers leaves plans unchanged" 0 $?
cmp -s "$SKILL" "$TMP/snap-skill"; check "missing plans markers leaves skill unchanged" 0 $?
cmp -s "$JSON" "$TMP/snap-json"; check "missing plans markers leaves pricing.json unchanged" 0 $?

echo "$pass passed"
exit $fail
