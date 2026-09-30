#!/usr/bin/env bash
# Every gated registry hook must belong to at least one profile. Hooks whose
# placement still needs an owner decision are listed below with that context.
set -euo pipefail

ROOT="${US157_TEST_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd -P)}"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
FAIL=0
pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
normalize_hook_id() { printf '%s' "$1" | tr -d '\r'; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
[ -f "$REGISTRY" ] || { echo "FAIL: hook registry not found at $REGISTRY" >&2; exit 1; }
[ -f "$GATE" ] || { echo "FAIL: hook gate not found at $GATE" >&2; exit 1; }
. "$GATE" --lib

# These three hooks were explicitly left inactive in MIGRATION.md and the
# registry-dispatch test. Their profile placement remains an owner decision.
DEFERRED_PROFILE_DECISION=" env-file-no-trailing-newline check-core-yaml-parity record-policy-retrieval "
GATED_COUNT="$(jq '[.hooks[][] | .hooks[] | select(.gated == true) | .id] | unique | length' "$REGISTRY")"
[ "$GATED_COUNT" -gt 0 ] || { echo "FAIL: registry contains no gated hooks" >&2; exit 1; }

while IFS= read -r hook_id || [ -n "$hook_id" ]; do
  [ -n "$hook_id" ] || continue
  hook_id="$(normalize_hook_id "$hook_id")"
  if is_in_minimal_profile "$hook_id" || is_in_standard_profile "$hook_id" || is_in_strict_profile "$hook_id"; then
    pass "$hook_id belongs to a profile"
  else
    case "$DEFERRED_PROFILE_DECISION" in
      *" $hook_id "*) pass "$hook_id remains deferred for an owner profile decision" ;;
      *) fail "gated registry id '$hook_id' is missing from every profile" ;;
    esac
  fi
done < <(jq -r '.hooks[][] | .hooks[] | select(.gated == true) | .id' "$REGISTRY" | sort -u)

# Commit history documents this hook as standard-profile behavior. Strict also
# carries it because that profile includes the standard hook set.
is_in_standard_profile capture-estimates \
  && pass "capture-estimates remains in the standard profile" \
  || fail "capture-estimates must be in the standard profile"
is_in_strict_profile capture-estimates \
  && pass "capture-estimates remains in the strict profile" \
  || fail "capture-estimates must be in the strict profile"

# Simulate jq output from Git Bash, which can terminate each ID with CRLF.
CRLF_ID="$(printf 'capture-estimates\r\n' | while IFS= read -r id; do normalize_hook_id "$id"; done)"
if [ "$CRLF_ID" = "capture-estimates" ] && is_in_standard_profile "$CRLF_ID"; then
  pass "CRLF-terminated registry id belongs to the standard profile"
else
  fail "CRLF-terminated registry id is not normalized before profile comparison"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "gated-hook-profile-coverage: $GATED_COUNT gated ids checked; all are profiled or explicitly deferred"
  exit 0
fi
echo "gated-hook-profile-coverage: $FAIL failure(s) across $GATED_COUNT gated ids" >&2
exit 1
