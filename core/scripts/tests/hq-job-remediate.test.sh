#!/usr/bin/env bash
# hq-core: public
# Regression: hq-job-remediate.sh allowlist (US-006).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REM="$ROOT/core/scripts/hq-job-remediate.sh"

[ -f "$REM" ] || { echo "FAIL: missing $REM" >&2; exit 1; }
[ -x "$REM" ] || chmod +x "$REM"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-job-remediate-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"
export HQ_JOB_REMEDIATE_DRY=1
export HQ_ROOT="$TMP/hq"
mkdir -p "$HQ_ROOT"

# 1) secrets → always-human, no retry
out="$(bash "$REM" --failure-class secrets --job-id j1)"
echo "$out" | jq -e '.always_human == true' >/dev/null || fail "secrets should be always_human: $out"
echo "$out" | jq -e '.retry_recommended == false' >/dev/null || fail "secrets must not retry"
echo "$out" | jq -r '.next_action' | grep -qi 'share' || fail "secrets next_action should mention share"
pass "secrets always-human"

# 2) auth → cognito refresh attempted (dry), never recommends device-login retry
cat >"$BIN/hq" <<'STUB'
#!/usr/bin/env bash
echo "hq-stub: $*" >>"${HQ_STUB_LOG:-/dev/null}"
exit 0
STUB
chmod +x "$BIN/hq"
export HQ_STUB_LOG="$TMP/stub.log"
: >"$HQ_STUB_LOG"
unset HQ_JOB_REMEDIATE_DRY
export HQ_JOB_REMEDIATE_AUTH_REFRESH_CMD="hq auth refresh"
export HQ_JOB_REMEDIATE_LOG="$TMP/rem.log"
out="$(bash "$REM" --failure-class auth --job-id j-auth)"
echo "$out" | jq -e '.always_human == true' >/dev/null || fail "auth always_human"
echo "$out" | jq -e '.retry_recommended == false' >/dev/null || fail "auth must not auto-retry agent"
echo "$out" | jq -r '.next_action' | grep -Eqi 're-login|device' || fail "auth next_action should name re-login"
echo "$out" | jq -e '.actions | index("cognito_token_refresh") != null' >/dev/null || fail "expected cognito_token_refresh action"
grep -q 'auth refresh' "$HQ_STUB_LOG" || fail "expected hq auth refresh invocation"
if grep -Eqi 'device-code|claude login|codex login' "$HQ_STUB_LOG"; then
  fail "must not device-login loop"
fi
pass "auth refreshes cognito only (no device-login loop)"

# 3) infra → sync pull + retry_recommended
: >"$HQ_STUB_LOG"
export HQ_JOB_REMEDIATE_SYNC_PULL_CMD="hq sync pull --personal"
out="$(bash "$REM" --failure-class infra --job-id j-infra --company indigo)"
echo "$out" | jq -e '.retry_recommended == true' >/dev/null || fail "infra should recommend retry: $out"
echo "$out" | jq -e '.actions | index("hq_sync_pull") != null' >/dev/null || fail "expected hq_sync_pull"
pass "infra sync + retry"

# 4) timeout / agent_error → no retry
out="$(bash "$REM" --failure-class timeout --job-id j-t)"
echo "$out" | jq -e '.retry_recommended == false' >/dev/null || fail "timeout no retry"
out="$(bash "$REM" --failure-class agent_error --job-id j-a)"
echo "$out" | jq -e '.retry_recommended == false' >/dev/null || fail "agent_error no retry"
pass "timeout and agent_error not retried"

echo "ALL PASSED (hq-job-remediate)"
