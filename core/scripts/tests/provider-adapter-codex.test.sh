#!/usr/bin/env bash
# hq-core: public
# provider-adapter-codex.test.sh — US-501 codex adapter (stub codex only).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$ROOT/core/scripts/lib"
ADAPTER_SH="$LIB/provider-adapter.sh"
PROBE="$ROOT/core/scripts/tests/probes/codex-capabilities.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# shellcheck disable=SC1090
. "$ADAPTER_SH"

# ---------------------------------------------------------------------------
# Load + id
# ---------------------------------------------------------------------------
if hq_adapter_load codex; then
  pass "hq_adapter_load codex exits 0"
else
  fail "hq_adapter_load codex failed"
fi

id="$(hq_adapter_id)"
if [[ "$id" == "codex" ]]; then
  pass "hq_adapter_id prints codex"
else
  fail "hq_adapter_id got '$id'"
fi

# ---------------------------------------------------------------------------
# Preflight on / off renders
# ---------------------------------------------------------------------------
task="/tmp/t.txt"
preflight_wd='"${HQ_AGENT_COMPANY_DIR:?session preflight company missing}"'
off_wd="/home/ec2-user/hq"

on_cmd="$(hq_adapter_build_invocation "$task" "$preflight_wd" on)"
off_cmd="$(hq_adapter_build_invocation "$task" "$off_wd" off)"

if [[ "$on_cmd" == *'cd "${HQ_AGENT_COMPANY_DIR:?session preflight company missing}"'* ]] \
  && [[ "$on_cmd" == *"codex exec --skip-git-repo-check"* ]] \
  && [[ "$on_cmd" == *"--dangerously-bypass-hook-trust"* ]] \
  && [[ "$on_cmd" == *"$task"* ]]; then
  pass "preflight on render"
else
  fail "preflight on render: $on_cmd"
fi

if [[ "$off_cmd" == *"cd /home/ec2-user/hq"* ]] \
  && [[ "$off_cmd" == *"codex exec --skip-git-repo-check"* ]] \
  && [[ "$off_cmd" != *"--dangerously-bypass-hook-trust"* ]] \
  && [[ "$off_cmd" == *"$task"* ]]; then
  pass "preflight off render"
else
  fail "preflight off render: $off_cmd"
fi

# Prompt-by-file: metacharacters in task path stay as path; no $(cat
meta_task='/tmp/t-`$(evil).txt'
on_meta="$(hq_adapter_build_invocation "$meta_task" "$preflight_wd" on)"
off_meta="$(hq_adapter_build_invocation "$meta_task" "$off_wd" off)"
for r in "$on_meta" "$off_meta"; do
  if [[ "$r" == *"$meta_task"* ]] && [[ "$r" != *'$(cat'* ]]; then
    pass "prompt-by-file (no \$(cat) in: ${r:0:60}…)"
  else
    fail "prompt-by-file violation: $r"
  fi
done

# Sandbox/approval flags absent
for r in "$on_cmd" "$off_cmd"; do
  if [[ "$r" != *"--sandbox"* ]] && [[ "$r" != *"--ask-for-approval"* ]]; then
    pass "no sandbox/approval flags"
  else
    fail "forbidden sandbox/approval flag in: $r"
  fi
done

# ---------------------------------------------------------------------------
# extract_reply
# ---------------------------------------------------------------------------
known="final assistant message from codex"
got="$(printf '%s' "$known" | hq_adapter_extract_reply)"
if [[ "$got" == "$known" ]]; then
  pass "extract_reply returns final message"
else
  fail "extract_reply got '$got'"
fi

set +e
empty_out="$(printf '   \n' | hq_adapter_extract_reply 2>/dev/null)"
empty_rc=$?
set -e
if [[ "$empty_rc" -eq 1 ]] && [[ -z "$empty_out" ]]; then
  pass "extract_reply empty/whitespace exits 1"
else
  fail "extract_reply empty: rc=$empty_rc out='$empty_out'"
fi

# ---------------------------------------------------------------------------
# capabilities enums
# ---------------------------------------------------------------------------
caps="$(hq_adapter_capabilities)"
for k in system_prompt resume hooks plan_mode durable_writes telegram_eligible usage_source; do
  if printf '%s\n' "$caps" | grep -q "^${k}="; then
    pass "capabilities has $k"
  else
    fail "capabilities missing $k"
  fi
done

# ---------------------------------------------------------------------------
# Probe: no codex on PATH → exit 2; stub → system_prompt probe 0
# ---------------------------------------------------------------------------
# Ensure real codex is not required: run probe with PATH stripped of codex.
set +e
probe_err="$(PATH="/usr/bin:/bin" bash "$PROBE" 2>&1)"
probe_rc=$?
set -e
if [[ "$probe_rc" -eq 2 ]]; then
  pass "probe exits 2 without codex"
else
  fail "probe without codex: rc=$probe_rc err=$probe_err"
fi

# Stub codex on PATH
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
# minimal stub for capability probes
if [[ "${1:-}" == "exec" && "${2:-}" == "--help" ]]; then
  echo "Usage: codex exec [OPTIONS] resume ..."
  exit 0
fi
echo "stub-codex-output"
exit 0
STUB
chmod +x "$TMP/bin/codex"
set +e
PATH="$TMP/bin:$PATH" bash "$PROBE" system_prompt >/dev/null 2>&1
probe_sys_rc=$?
set -e
if [[ "$probe_sys_rc" -eq 0 ]]; then
  pass "probe system_prompt exits 0 with stub codex"
else
  fail "probe system_prompt with stub: rc=$probe_sys_rc"
fi

# Full suite under stub PATH (no real codex required for adapter tests)
export PATH="$TMP/bin:$PATH"

if [[ "$FAIL" -eq 0 ]]; then
  echo "provider-adapter-codex: all passed"
  exit 0
fi
echo "provider-adapter-codex: $FAIL failed" >&2
exit 1
