#!/usr/bin/env bash
# Regression: the /dm skill must CONFIRM a recipient's email before sending,
# resolving names through the built-in `hq people resolve` lookup
# (feature-dm-skill-email-confirm) instead of sending to an unconfirmed
# recipient. `hq dm`'s `allowed-tools` is `Bash(hq:*)`, so the skill calls the
# `hq people` CLI directly — this is an instruction skill, so the contract is
# structural: the SKILL.md must wire the resolve path and handle every outcome.
#
# Guards:
#   1. Name resolution goes through `hq people resolve` (+ `hq people search`
#      for ambiguous browsing).
#   2. All four resolver statuses are handled (found / ambiguous / no_email /
#      not_found) and each non-found case STOPS rather than sending blind.
#   3. Resolution is single-company and tenancy-safe (scoped via --company /
#      the active company), never fanned across every company.
#   4. The email / personUid fast path is preserved (passed through verbatim).
#   5. The old cross-company glob-everything resolution is gone (negative).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/dm/SKILL.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$SKILL" ] || fail "missing dm skill: $SKILL"

# 1. Resolve + search wired in
grep -q 'hq people resolve' "$SKILL" \
  || fail "dm skill must resolve names via 'hq people resolve'"
grep -q 'hq people search' "$SKILL" \
  || fail "dm skill must reference 'hq people search' for ambiguous candidates"

# 2. Every resolver status is handled
for status in found ambiguous no_email not_found; do
  grep -q "status: \"$status\"" "$SKILL" \
    || fail "dm skill must handle resolver status '$status'"
done

# 2b. Non-found cases must STOP (not send blind); confirm-before-send is explicit
grep -qi 'never send blind' "$SKILL" \
  || fail "dm skill must state it never sends to an unconfirmed recipient"
# At least two explicit STOP directives for the failure branches
[ "$(grep -c 'STOP' "$SKILL")" -ge 2 ] \
  || fail "dm skill must STOP on ambiguous / no_email / not_found branches"

# 3. Single-company + tenancy-safe scoping
grep -qi 'single-company' "$SKILL" \
  || fail "dm skill must state resolution is single-company"
grep -qi 'tenancy' "$SKILL" \
  || fail "dm skill must call out tenancy-safety"
grep -q -- '--company' "$SKILL" \
  || fail "dm skill must document --company scoping"

# 4. Fast path preserved
grep -qi 'fast path' "$SKILL" \
  || fail "dm skill must preserve the email/personUid fast path"
grep -q 'verbatim' "$SKILL" \
  || fail "dm skill must pass an email/personUid through verbatim"

# 5. Negative: the old cross-company glob-everything resolution must be gone
if grep -q 'covers \*\*all\*\* the companies' "$SKILL"; then
  fail "dm skill still instructs cross-company glob resolution (should be single-company via hq people resolve)"
fi

echo "dm-people-resolve-integration: ok (confirm-before-send via hq people resolve; single-company, tenancy-safe; all statuses handled)"
