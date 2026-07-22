#!/usr/bin/env bash
# hq-core: public
# provider-adapter-grok.test.sh — US-501/US-502 grok adapter (stub grok only).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$ROOT/core/scripts/lib"
ADAPTER_SH="$LIB/provider-adapter.sh"
PROBE="$ROOT/core/scripts/tests/probes/grok-capabilities.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# shellcheck disable=SC1090
. "$ADAPTER_SH"

if hq_adapter_load grok; then
  pass "hq_adapter_load grok exits 0"
else
  fail "hq_adapter_load grok failed"
fi

id="$(hq_adapter_id)"
if [[ "$id" == "grok" ]]; then
  pass "hq_adapter_id prints grok"
else
  fail "hq_adapter_id got '$id'"
fi

task="/tmp/t.txt"
preflight_wd='"${HQ_AGENT_COMPANY_DIR:?session preflight company missing}"'
off_wd="/home/ec2-user/hq"

on_cmd="$(hq_adapter_build_invocation "$task" "$preflight_wd" on)"
off_cmd="$(hq_adapter_build_invocation "$task" "$off_wd" off)"

_assert_grok_render() {
  local r="$1" label="$2" expected_wd="$3"
  local ok=1
  [[ "$r" == *"cd ${expected_wd}"* ]] || ok=0
  [[ "$r" == *'K="$(cat /home/ec2-user/.grok/key 2>/dev/null || true)"'* ]] || ok=0
  [[ "$r" == *'export XAI_API_KEY="$K"'* ]] || ok=0
  [[ "$r" == *"/home/ec2-user/.grok/bin/grok -p"* ]] || ok=0
  [[ "$r" == *"--yolo"* ]] || ok=0
  [[ "$r" == *"--no-auto-update"* ]] || ok=0
  [[ "$r" == *"$task"* ]] || ok=0
  if [[ "$ok" -eq 1 ]]; then
    pass "grok render ($label)"
  else
    fail "grok render ($label): $r"
  fi
}

_assert_grok_render "$on_cmd" "preflight-on" "$preflight_wd"
_assert_grok_render "$off_cmd" "preflight-off" "$off_wd"

# Prompt-by-file: no $(cat after grok -p; key-file $(cat retained
meta_task='/tmp/t-`$(evil).txt'
for mode_wd in "$preflight_wd" "$off_wd"; do
  r="$(hq_adapter_build_invocation "$meta_task" "$mode_wd" off)"
  after_p="${r#*grok -p }"
  if [[ "$r" == *"$meta_task"* ]] \
    && [[ "$after_p" != *'$(cat'* ]] \
    && [[ "$r" == *'K="$(cat /home/ec2-user/.grok/key 2>/dev/null || true)"'* ]]; then
    pass "prompt-by-file keeps key preamble, no task \$(cat)"
  else
    fail "prompt-by-file: $r"
  fi
done

# Subscription-mode regression: key ABSENT must still reach grok
mkdir -p "$TMP/bin"
cat > "$TMP/bin/grok-reached" <<'STUB'
#!/usr/bin/env bash
echo REACHED_GROK
exit 0
STUB
chmod +x "$TMP/bin/grok-reached"
# Rewrite full-path binary + key path to temp (key path intentionally missing)
snippet="$(hq_adapter_build_invocation "$task" "$TMP" off)"
snippet="${snippet//\/home\/ec2-user\/.grok\/bin\/grok/$TMP\/bin\/grok-reached}"
snippet="${snippet//\/home\/ec2-user\/.grok\/key/$TMP\/absent-key-on-purpose}"
# Drop the task-file argv requirement for reachability (stub ignores args)
set +e
out="$(bash -c "$snippet" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && [[ "$out" == *"REACHED_GROK"* ]]; then
  pass "subscription-mode: missing key still reaches grok"
else
  fail "subscription-mode short-circuit: rc=$rc out=$out snippet=$snippet"
fi

# capabilities: plan_mode=absent usage_source=unavailable
caps="$(hq_adapter_capabilities)"
plan="$(printf '%s\n' "$caps" | sed -n 's/^plan_mode=//p')"
usage="$(printf '%s\n' "$caps" | sed -n 's/^usage_source=//p')"
if [[ "$plan" == "absent" && "$usage" == "unavailable" ]]; then
  pass "plan_mode=absent usage_source=unavailable"
else
  fail "caps plan_mode=$plan usage_source=$usage"
fi

# extract_reply
known="final assistant message from grok"
got="$(printf '%s' "$known" | hq_adapter_extract_reply)"
if [[ "$got" == "$known" ]]; then
  pass "extract_reply returns final message"
else
  fail "extract_reply got '$got'"
fi
set +e
empty_out="$(printf '' | hq_adapter_extract_reply 2>/dev/null)"
empty_rc=$?
set -e
if [[ "$empty_rc" -eq 1 ]]; then
  pass "extract_reply empty exits 1"
else
  fail "extract_reply empty: rc=$empty_rc out='$empty_out'"
fi

# Probe exit 2 when neither PATH grok nor default path present
set +e
probe_err="$(PATH="/usr/bin:/bin" bash "$PROBE" 2>&1)"
probe_rc=$?
set -e
if [[ "$probe_rc" -eq 2 ]]; then
  pass "probe exits 2 without grok"
else
  # If /home/ec2-user/.grok/bin/grok happens to exist on this host, skip soft
  if [[ -x /home/ec2-user/.grok/bin/grok ]]; then
    pass "probe not skip (real grok path present on host)"
  else
    fail "probe without grok: rc=$probe_rc err=$probe_err"
  fi
fi

# Stub on PATH — full suite path for green CI
cat > "$TMP/bin/grok" <<'STUB'
#!/usr/bin/env bash
echo "stub-grok-output"
exit 0
STUB
chmod +x "$TMP/bin/grok"
export PATH="$TMP/bin:$PATH"

if [[ "$FAIL" -eq 0 ]]; then
  echo "provider-adapter-grok: all passed"
  exit 0
fi
echo "provider-adapter-grok: $FAIL failed" >&2
exit 1
