#!/usr/bin/env bash
# hq-core: public
# provider-adapter-claude.test.sh — US-501/US-503 claude adapter (stub pty only).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$ROOT/core/scripts/lib"
ADAPTER_SH="$LIB/provider-adapter.sh"
PROBE="$ROOT/core/scripts/tests/probes/claude-capabilities.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# shellcheck disable=SC1090
. "$ADAPTER_SH"

if hq_adapter_load claude; then
  pass "hq_adapter_load claude exits 0"
else
  fail "hq_adapter_load claude failed"
fi

id="$(hq_adapter_id)"
if [[ "$id" == "claude" ]]; then
  pass "hq_adapter_id prints claude"
else
  fail "hq_adapter_id got '$id'"
fi

task="/tmp/t.txt"
preflight_wd='"${HQ_AGENT_COMPANY_DIR:?session preflight company missing}"'
off_wd="/home/ec2-user/hq"
dispatch="/usr/local/bin/hq-agent-claude-dispatch.sh"

_assert_claude_render() {
  local r="$1" label="$2" expected_wd="$3"
  local ok=1
  [[ "$r" == *"cd ${expected_wd}"* ]] || ok=0
  [[ "$r" == *"HQ_AGENT_CLAUDE_TASKFILE=${task}"* ]] || ok=0
  [[ "$r" == *"$dispatch"* ]] || ok=0
  [[ "$r" != *"claude -p"* ]] || ok=0
  [[ "$r" != *[Aa]gent\ [Ss][Dd][Kk]* ]] || ok=0
  [[ "$r" != *"--dangerously-skip-permissions"* ]] || ok=0
  [[ "$r" != *"--permission-mode"* ]] || ok=0
  if [[ "$ok" -eq 1 ]]; then
    pass "claude render ($label)"
  else
    fail "claude render ($label): $r"
  fi
}

unset HQ_AGENT_CLAUDE_TIMEOUT_SECONDS 2>/dev/null || true
on_cmd="$(hq_adapter_build_invocation "$task" "$preflight_wd" on)"
off_cmd="$(hq_adapter_build_invocation "$task" "$off_wd" off)"
_assert_claude_render "$on_cmd" "preflight-on" "$preflight_wd"
_assert_claude_render "$off_cmd" "preflight-off" "$off_wd"

# Default timeout 280 when unset
if [[ "$on_cmd" == *"HQ_AGENT_CLAUDE_TIMEOUT_SECONDS=280"* ]]; then
  pass "default timeout 280"
else
  fail "expected default timeout 280 in: $on_cmd"
fi

# Optional 4th arg transcript path file
tx_expr='$CLAUDE_TRANSCRIPT_PATH_FILE'
with_tx="$(hq_adapter_build_invocation "$task" "$off_wd" off "$tx_expr")"
if [[ "$with_tx" == *" HQ_AGENT_CLAUDE_TRANSCRIPT_PATH_FILE='${tx_expr}'"* ]] \
  && [[ "$with_tx" == *"HQ_AGENT_CLAUDE_TASKFILE=${task}"* ]] \
  && [[ "$with_tx" == *"$dispatch"* ]]; then
  # Position: taskfile assignment before transcript env before wrapper
  task_pos="${with_tx%%HQ_AGENT_CLAUDE_TASKFILE=*}"
  # shellcheck disable=SC2295
  rest="${with_tx#*HQ_AGENT_CLAUDE_TASKFILE=${task}}"
  if [[ "$rest" == *"HQ_AGENT_CLAUDE_TRANSCRIPT_PATH_FILE="*"$dispatch"* ]]; then
    pass "transcript path file segment position"
  else
    fail "transcript segment order: $with_tx"
  fi
else
  fail "transcript path file render: $with_tx"
fi

# Omitted 4th arg → no TRANSCRIPT env at all
if [[ "$off_cmd" != *"HQ_AGENT_CLAUDE_TRANSCRIPT_PATH_FILE"* ]]; then
  pass "omitted transcript segment"
else
  fail "unexpected transcript in: $off_cmd"
fi

# Timeout >= 300 fails
set +e
err300="$(HQ_AGENT_CLAUDE_TIMEOUT_SECONDS=300 hq_adapter_build_invocation "$task" "$off_wd" off 2>&1)"
rc300=$?
set -e
if [[ "$rc300" -eq 1 ]]; then
  pass "timeout 300 exits 1"
else
  fail "timeout 300 should fail: rc=$rc300 err=$err300"
fi

# extract_reply: empty stdout → exit 1; no RUN_DIR references in adapter source
set +e
empty_out="$(printf '' | hq_adapter_extract_reply 2>/dev/null)"
empty_rc=$?
set -e
if [[ "$empty_rc" -eq 1 ]] && [[ -z "${empty_out:-}" ]]; then
  pass "extract_reply empty exits 1"
else
  fail "extract_reply empty: rc=$empty_rc out='$empty_out'"
fi

known="final assistant message from claude"
got="$(printf '%s' "$known" | hq_adapter_extract_reply)"
if [[ "$got" == "$known" ]]; then
  pass "extract_reply returns final message"
else
  fail "extract_reply got '$got'"
fi

adapter_src="$LIB/provider-adapters/claude.sh"
if ! grep -E '\$RUN_DIR|\$\{RUN_DIR' "$adapter_src" >/dev/null 2>&1; then
  pass "adapter source has no RUN_DIR references"
else
  fail "adapter must not reference RUN_DIR"
fi

# capabilities
caps="$(hq_adapter_capabilities)"
tg="$(printf '%s\n' "$caps" | sed -n 's/^telegram_eligible=//p')"
us="$(printf '%s\n' "$caps" | sed -n 's/^usage_source=//p')"
if [[ "$tg" == "no" && "$us" == "transcript" ]]; then
  pass "telegram_eligible=no usage_source=transcript"
else
  fail "caps telegram=$tg usage=$us"
fi

# Probe exit 2 when dispatch not installed
set +e
probe_err="$(PATH="/usr/bin:/bin" HQ_AGENT_CLAUDE_DISPATCH="$TMP/no-such-dispatch" bash "$PROBE" 2>&1)"
# Probe hardcodes path unless we can't override — check default absence
probe_err2="$(bash "$PROBE" 2>&1)"
probe_rc=$?
set -e
# If the real dispatch is installed on this machine, accept exit 0; else expect 2
if [[ ! -f /usr/local/bin/hq-agent-claude-dispatch.sh ]]; then
  if [[ "$probe_rc" -eq 2 ]]; then
    pass "probe exits 2 without dispatch wrapper"
  else
    fail "probe without dispatch: rc=$probe_rc err=$probe_err2"
  fi
else
  pass "probe path present on host (skip exit-2 assertion)"
fi

# Stub pty via HQ_AGENT_CLAUDE_PTY (documented for dispatch wrapper tests)
export HQ_AGENT_CLAUDE_PTY="$TMP/stub-pty"
cat > "$HQ_AGENT_CLAUDE_PTY" <<'STUB'
#!/usr/bin/env bash
# stub pty spawner — no real claude CLI
exit 0
STUB
chmod +x "$HQ_AGENT_CLAUDE_PTY"

if [[ "$FAIL" -eq 0 ]]; then
  echo "provider-adapter-claude: all passed"
  exit 0
fi
echo "provider-adapter-claude: $FAIL failed" >&2
exit 1
