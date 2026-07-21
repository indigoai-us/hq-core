#!/usr/bin/env bash
# verify-gate-policy-endpoint.test.sh
#
# Regression for the 2026-07-19 live-smoke finding: verify_gate proved a
# company gate by reading `.accessPolicy.companyUid` from GET /api/apps/{id}.
# That endpoint returns accessPolicy: null for EVERY app, gated or not, so the
# check could never pass — and the "unverified" branch then overwrote the
# correct company gate with a password gate on every company deploy.
#
# A verification that cannot pass is worse than none: it destroyed the thing
# it was checking, and it reported success while doing so. No unit test caught
# it because every one of them mocked the API shape.
#
# This asserts the SHAPE the script depends on, against fixtures matching what
# the live API actually returns.
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy-summary.sh"
FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: needs jq"; exit 0; }
[ -f "$SCRIPT" ] || { echo "SKIP: $SCRIPT not found"; exit 0; }

# Real captured responses for a genuinely company-gated app (2026-07-19).
APP_RESPONSE='{"accessMode":"company","passwordProtected":false,"accessPolicy":null,"companyUid":null}'
POLICY_RESPONSE='{"appId":"x","orgSlug":"indigo","mode":"company","companyUid":"cmp_TEST","users":[],"groups":[],"policyVersion":2}'
EXPECTED_UID="cmp_TEST"

# --- the shape assertions the fix depends on -------------------------------
if [ "$(printf '%s' "$APP_RESPONSE" | jq -r '.accessPolicy.companyUid // empty')" = "" ]; then
  pass "GET /api/apps/{id} yields NO accessPolicy.companyUid (the trap)"
else
  fail "fixture drift: app response now carries accessPolicy.companyUid"
fi

if [ "$(printf '%s' "$POLICY_RESPONSE" | jq -r '.companyUid // empty')" = "$EXPECTED_UID" ]; then
  pass "GET /api/apps/{id}/access-policy carries the real companyUid"
else
  fail "policy endpoint fixture does not expose companyUid"
fi

# The old logic, replayed against real shapes, must be shown to fail — that is
# what makes this regression meaningful rather than decorative.
old_uid="$(printf '%s' "$APP_RESPONSE" | jq -r '.accessPolicy.companyUid // empty')"
if [ "$old_uid" = "$EXPECTED_UID" ]; then
  fail "old verification would have passed — fixture no longer reproduces the bug"
else
  pass "old verification provably fails on a correctly gated app"
fi

new_mode="$(printf '%s' "$POLICY_RESPONSE" | jq -r '.mode // empty')"
new_uid="$(printf '%s' "$POLICY_RESPONSE" | jq -r '.companyUid // empty')"
if [ "$new_mode" = "company" ] && [ "$new_uid" = "$EXPECTED_UID" ]; then
  pass "new verification passes on a correctly gated app"
else
  fail "new verification fails on a correctly gated app"
fi

# --- the script must actually query the policy endpoint --------------------
if grep -q 'api/apps/\$APP_ID/access-policy' "$SCRIPT"; then
  pass "deploy-summary.sh reads the access-policy endpoint"
else
  fail "deploy-summary.sh does not query /access-policy — the trap is back"
fi

# ...and must NOT gate company verification on the always-null app field.
if grep -n 'accessPolicy.companyUid' "$SCRIPT" | grep -qv '^[0-9]*:[[:space:]]*#'; then
  fail "a non-comment line still reads .accessPolicy.companyUid"
else
  pass "no live code path reads the always-null .accessPolicy.companyUid"
fi

if [ "$FAIL" = "0" ]; then echo "ALL PASS"; exit 0; else echo "FAILURES"; exit 1; fi
