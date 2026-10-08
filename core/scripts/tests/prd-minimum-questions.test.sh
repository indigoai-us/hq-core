#!/bin/bash
# prd-minimum-questions.test.sh — verifies the prd-minimum-questions check
# (core/scripts/prd-interview-check.sh) and the prd question set it counts.
#
# Fixtures: core/scripts/tests/fixtures/prd-minimum-questions/
#   with-brainstorm.prd.json  6 asked + 4 loaded from brainstorm -> pass
#   no-brainstorm.prd.json    6 asked + 0 loaded                 -> 6/10 warning
#   one-tier.prd.json         12 total, asked in 1 tier          -> tier warning

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/core/scripts/prd-interview-check.sh"
FRONTIER="$REPO_ROOT/.claude/skills/grilling/frontier.sh"
QSET="$REPO_ROOT/.claude/skills/_shared/questions/prd.md"
POLICY="$REPO_ROOT/core/policies/prd-minimum-questions.md"
FIX="$SCRIPT_DIR/fixtures/prd-minimum-questions"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }
expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi
}

echo "prd-minimum-questions.test.sh"

for f in "$CHECK" "$FRONTIER" "$QSET" "$POLICY"; do
  [ -f "$f" ] || { echo "  FAIL: missing $f"; exit 1; }
done

# 1. 6 asked + 4 loaded from brainstorm passes.
out=$(bash "$CHECK" "$FIX/with-brainstorm.prd.json"); rc=$?
expect_eq "6 asked + 4 known exits 0" "$rc" "0"
expect_eq "6 asked + 4 known message" "$out" "OK: 10/10 answered across 3 tiers"

# 2. 6 asked + 0 loaded fails with the N/10 warning.
out=$(bash "$CHECK" "$FIX/no-brainstorm.prd.json"); rc=$?
expect_eq "6 asked + 0 known exits 1" "$rc" "1"
expect_eq "6 asked + 0 known warning" "$out" "WARN: 6/10 answered"

# 3. Enough questions but only one tier fails the tier rule.
out=$(bash "$CHECK" "$FIX/one-tier.prd.json"); rc=$?
expect_eq "single tier exits 1" "$rc" "1"
expect_eq "single tier warning" "$out" "WARN: 1/3 tiers covered (need 2)"

# 4. The prd question set is valid and spans all three tiers.
out=$(bash "$FRONTIER" count "$QSET"); rc=$?
expect_eq "question set validates" "$rc" "0"
tiers=$(printf '%s' "$out" | python3 -c 'import json,sys; print(sum(1 for v in json.load(sys.stdin)["by_tier"].values() if v > 0))')
expect_eq "question set spans 3 tiers" "$tiers" "3"
for b in 1a 1b 1c 2a 2b 2c 3a 3b 3c 3d 4a 4b 4c 4d 5a 5b 5c 6a 6b 6c 6d 6e 6f 6g 6h 7a; do
  grep -q "^## Q-$b\$" "$QSET" || bad "question set missing Q-$b"
done
ok "question set covers Batches 1 to 7"

# 5. Batch 4 to 6 conditionals depend on the project_type fact.
grep -A5 '^## project_type$' "$QSET" | grep -q 'kind: fact' && ok "project_type is a fact" || bad "project_type is not a fact"
for b in 4a 4b 4c 4d 5a 5b 5c 6g 6h; do
  awk -v id="## Q-$b" '$0==id{f=1;next} /^## /{f=0} f' "$QSET" | grep -q 'depends_on: \[project_type\]' \
    || bad "Q-$b does not depend on project_type"
done
ok "conditional questions depend on project_type"

# 6. Brainstorm answers load as known: 5 recorded answers are skipped, not asked.
full=$(bash "$FRONTIER" count "$QSET" | python3 -c 'import json,sys; print(json.load(sys.stdin)["asked"])')
out=$(bash "$FRONTIER" count "$QSET" --known Q-1a,Q-1b,Q-2a,Q-3b,Q-5a)
known=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["skipped_known"])')
asked=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["asked"])')
expect_eq "5 brainstorm answers skipped_known" "$known" "5"
expect_eq "5 brainstorm answers not asked" "$asked" "$((full - 5))"

# 7. Policy text: count includes brainstorm answers, when: trigger unchanged.
grep -q '^when: prd || plan$' "$POLICY" && ok "policy when: trigger unchanged" || bad "policy when: trigger changed"
grep -q 'asked + skipped_known' "$POLICY" && ok "policy counts asked + skipped_known" || bad "policy count rule missing"
grep -q '2 of the 3 tiers' "$POLICY" && ok "policy requires 2 of 3 tiers" || bad "policy tier rule missing"

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
