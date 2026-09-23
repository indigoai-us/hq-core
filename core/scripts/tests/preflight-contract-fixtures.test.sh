#!/usr/bin/env bash
# hq-core: public
# Pins the vendored offline preflight contract at version 1 and runs the
# installed-cli diff when hq-cli is present.
#
# To bump contractVersion, update all of:
#   - this assertion
#   - core/hooks/SessionStart/preflight-fixtures.json
#   - hq-cli WORK_CONTEXT_CONTRACT_VERSION
#   - hq-cli contracts/preflight/v<N>/schema.json and fixtures.json
#   - hq-cli src/lib/work-context/preflight-contract.test.ts pin
# A one-sided bump fails the pin on that side. When both packages are on the
# machine, check-preflight-fixtures.sh fails until the bytes match.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURES="$ROOT/core/hooks/SessionStart/preflight-fixtures.json"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

jq -e '.contractVersion == 1' "$FIXTURES" >/dev/null \
  && pass "contractVersion pin is 1" \
  || fail "contractVersion pin drifted"
jq -e '.source == "hq-cli contracts/preflight/v1/fixtures.json"' "$FIXTURES" >/dev/null \
  && pass "SOURCE names the hq-cli path" \
  || fail "SOURCE note missing"
jq -e '[.classifications[]] == [.fixtures[].classification]' "$FIXTURES" >/dev/null \
  && pass "one fixture per classification" \
  || fail "fixture/classification mismatch"

grep -q 'preflight-fixtures.json' "$ROOT/core/hooks/SessionStart/35-work-mesh-session-start.sh" \
  && pass "hook loads the vendored fixtures" \
  || fail "hook does not load preflight-fixtures.json"

if bash "$ROOT/core/scripts/check-preflight-fixtures.sh"; then
  pass "installed hq-cli diff"
else
  fail "installed hq-cli fixtures differ from the vendored copy"
fi

[ "$FAIL" -eq 0 ] || exit 1
