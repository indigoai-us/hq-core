#!/usr/bin/env bash
# hq-load-company-hard-policies-on-mid-session-bind.test.sh
#
# Pins the mid-session company-bind credential rule after feedback 2305:
# unattended HQ agents stay vault-only; an interactive assistant may honor
# an owner-authorized named company AWS profile. The blanket "agent sessions
# have NO local AWS-profile fallback" line is what blocked a verified owner.
#
# This policy is enforcement: hard, so its Rule body is injected verbatim.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
POLICY="$ROOT/core/policies/hq-load-company-hard-policies-on-mid-session-bind.md"
CRED="$ROOT/core/policies/credential-access-protocol.md"

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok — $1"; }

[ -f "$POLICY" ] || fail "missing $POLICY"
[ -f "$CRED" ] || fail "missing $CRED"

echo "mid-session-bind: still hard, and still within the injected-body budget"
grep -q '^enforcement: hard' "$POLICY" || fail "policy must stay enforcement: hard"
body="$(awk '/^## Rationale|^## Background|^## Change history|^## Examples|^## References/{exit}{print}' "$POLICY" | wc -c)"
cap="${HQ_POLICY_HARD_RULE_MAX_BYTES:-6144}"
[ "$body" -le "$cap" ] || fail "injected body is $body bytes, over the $cap-byte hard-policy cap"
ok "hard enforcement retained, body is $body/$cap bytes"

echo "mid-session-bind: company policies still load on mid-session bind"
grep -q 'companies/{co}/policies/' "$POLICY" \
  || fail "must still require reading companies/{co}/policies/ on bind"
grep -qi 'BEFORE any infrastructure' "$POLICY" \
  || fail "must still require loading company policies before infra/credential work"
ok "mid-session company policy load is intact"

echo "mid-session-bind: unattended HQ agents stay vault-only"
grep -qi 'Unattended HQ agents' "$POLICY" \
  || fail "must name unattended HQ agents as the vault-only audience"
grep -q 'hq secrets exec' "$POLICY" \
  || fail "unattended path must still name hq secrets exec"
grep -qi 'no local AWS-profile fallback' "$POLICY" \
  || fail "unattended path must still forbid a local AWS-profile fallback"
ok "unattended agents remain vault-only with no local profile fallback"

echo "mid-session-bind: interactive owner-authorized named profiles are allowed"
grep -qi 'Interactive assistants' "$POLICY" \
  || fail "must name interactive assistants as a distinct audience"
grep -qi 'named local AWS profile' "$POLICY" \
  || fail "must allow a named local AWS profile on the interactive path"
grep -qi 'explicitly named the profile' "$POLICY" \
  || fail "interactive path must require the member to name the profile"
grep -q 'aws_profile' "$POLICY" \
  || fail "interactive path must pin the name to the company manifest aws_profile"
grep -q 'aws sts get-caller-identity' "$POLICY" \
  || fail "interactive path must verify the profile account"
grep -q '~/.aws/credentials' "$POLICY" \
  || fail "interactive path must forbid reading ~/.aws/credentials"
ok "interactive owner-authorized named profile path is present and gated"

echo "mid-session-bind: the blanket agent-session ban is gone"
if grep -qi 'agent sessions have NO local AWS-profile fallback' "$POLICY"; then
  fail "blanket 'agent sessions have NO local AWS-profile fallback' would block interactive owners again"
fi
grep -qi 'never fall back to another company' "$POLICY" \
  || fail "must still forbid falling back to another company's profile"
ok "blanket agent-session ban is gone; cross-company fallback is still forbidden"

echo "credential-access-protocol: agrees on unattended vs interactive"
grep -q 'hq secrets exec' "$CRED" \
  || fail "credential-access-protocol must name hq secrets exec for unattended agents"
grep -qi 'interactive owner-authorized named profiles' "$CRED" \
  || fail "credential-access-protocol must point interactive named profiles at the bind policy"
grep -q 'hq-load-company-hard-policies-on-mid-session-bind' "$CRED" \
  || fail "credential-access-protocol must cite the bind policy"
ok "credential-access-protocol stays aligned"

echo
echo "hq-load-company-hard-policies-on-mid-session-bind.test.sh: $PASS checks passed"
