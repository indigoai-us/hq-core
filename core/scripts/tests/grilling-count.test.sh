#!/bin/bash
# grilling-count.test.sh — verifies the grilling engine helper's frontier and
# count object against the fixture question set.
#
# Fixture: core/scripts/tests/fixtures/grilling/sample-questions.md
#   12 questions, 3 pre-known, 2 facts -> asked=7.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/.claude/skills/grilling/frontier.sh"
FIXTURE="$SCRIPT_DIR/fixtures/grilling/sample-questions.md"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }

expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi
}

echo "grilling-count.test.sh"

[ -f "$HELPER" ] || { echo "  FAIL: helper missing at $HELPER"; exit 1; }
[ -f "$FIXTURE" ] || { echo "  FAIL: fixture missing at $FIXTURE"; exit 1; }

total=$(grep -c '^## ' "$FIXTURE")
expect_eq "fixture has 12 questions" "$total" "12"
facts=$(grep -c '^- kind: fact' "$FIXTURE")
expect_eq "fixture has 2 facts" "$facts" "2"

KNOWN="Q-users,Q-scope,Q-naming"

# 1. Count object for the full run.
out=$(bash "$HELPER" count "$FIXTURE" --known "$KNOWN")
rc=$?
expect_eq "count exits 0" "$rc" "0"
expected='{"asked": 7, "by_tier": {"architecture": 3, "quality": 3, "strategic": 1}, "skipped_fact": 2, "skipped_known": 3}'
expect_eq "count object" "$out" "$expected"

# 2. No known facts: every decision is asked, facts still skipped.
out=$(bash "$HELPER" count "$FIXTURE")
expect_eq "count with nothing known" "$out" \
  '{"asked": 10, "by_tier": {"architecture": 3, "quality": 4, "strategic": 3}, "skipped_fact": 2, "skipped_known": 0}'

# 3. First frontier with nothing known: only decisions with no open deps.
out=$(bash "$HELPER" frontier "$FIXTURE" | tr '\n' ' ')
expect_eq "initial frontier" "$out" "Q-users Q-naming "

# 4. Frontier never contains a fact, and waits on unanswered dependencies.
out=$(bash "$HELPER" frontier "$FIXTURE" --known "$KNOWN" | tr '\n' ' ')
expect_eq "frontier after known" "$out" "Q-success Q-storage Q-docs "
if bash "$HELPER" frontier "$FIXTURE" --known "$KNOWN" | grep -qE '^Q-(runtime|existing)$'; then
  bad "frontier includes a fact question"
else
  ok "frontier excludes fact questions"
fi

# 5. A fact resolves once its own deps resolve, unblocking downstream decisions.
out=$(bash "$HELPER" frontier "$FIXTURE" --known "$KNOWN" --answered "Q-success,Q-storage,Q-docs" | tr '\n' ' ')
expect_eq "frontier after round one" "$out" "Q-api "

# 6. Malformed sets are rejected.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '## Q-a\n- tier: strategic\n- kind: decision\n- depends_on: [Q-b]\n- options: X | Y\n- recommended: X\n## Q-b\n- tier: strategic\n- kind: decision\n- depends_on: [Q-a]\n- options: X | Y\n- recommended: X\n' > "$tmp/cycle.md"
bash "$HELPER" count "$tmp/cycle.md" >/dev/null 2>&1
expect_eq "cycle exits 2" "$?" "2"
printf '## Q-a\n- tier: strategic\n- kind: decision\n- depends_on: []\n- options: X\n- recommended: X\n' > "$tmp/one-option.md"
bash "$HELPER" count "$tmp/one-option.md" >/dev/null 2>&1
expect_eq "single-option decision exits 2" "$?" "2"

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
