#!/usr/bin/env bash
# hq-core: public
# provider-adapter-contract.test.sh — US-500 contract surface (no real providers).
#
# Asserts loader, version single-source, capability descriptor shape/enums,
# build_invocation arity + prompt-by-file rule, and that the suite runs with
# no codex/grok/claude binary required.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$ROOT/core/scripts/lib"
ADAPTER="$LIB/provider-adapter.sh"
VERSION_SH="$LIB/provider-adapter-version.sh"
DOC="$ROOT/core/docs/hq/provider-adapter-contract.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Guard: suite must not require real provider CLIs.
for bin in codex grok claude; do
  if command -v "$bin" >/dev/null 2>&1; then
    # Presence is fine; we never invoke them. Record for diagnostics only.
    :
  fi
done

# ---------------------------------------------------------------------------
# 1. Source defines five functions + loader; providers list; version from file
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
. "$ADAPTER"

for fn in hq_adapter_id hq_adapter_capabilities hq_adapter_build_invocation \
          hq_adapter_extract_reply hq_adapter_emit_usage hq_adapter_load; do
  if declare -F "$fn" >/dev/null 2>&1; then
    pass "defined: $fn"
  else
    fail "missing function after source: $fn"
  fi
done

if [[ "${HQ_ADAPTER_PROVIDERS:-}" == "codex grok claude" ]]; then
  pass "HQ_ADAPTER_PROVIDERS=$HQ_ADAPTER_PROVIDERS"
else
  fail "HQ_ADAPTER_PROVIDERS expected 'codex grok claude', got '${HQ_ADAPTER_PROVIDERS:-}'"
fi

if [[ -n "${HQ_ADAPTER_CONTRACT_VERSION:-}" ]]; then
  pass "HQ_ADAPTER_CONTRACT_VERSION=$HQ_ADAPTER_CONTRACT_VERSION"
else
  fail "HQ_ADAPTER_CONTRACT_VERSION empty after sourcing provider-adapter.sh"
fi

# Version file is the only place the assignment literal appears.
assign_hits="$(grep -RnE 'HQ_ADAPTER_CONTRACT_VERSION=' \
  "$ROOT/core/scripts" "$ROOT/core/docs" 2>/dev/null \
  | grep -v 'provider-adapter-version\.sh' \
  | grep -v 'provider-adapter-contract\.test\.sh' \
  | grep -v 'provider-adapter-delivery\.test\.sh' \
  || true)"
if [[ -z "$assign_hits" ]]; then
  pass "HQ_ADAPTER_CONTRACT_VERSION assignment only in version.sh"
else
  fail "HQ_ADAPTER_CONTRACT_VERSION redefined outside version.sh: $assign_hits"
fi

# provider-adapter.sh must source the version file, not hardcode the value.
if grep -q 'provider-adapter-version\.sh' "$ADAPTER"; then
  pass "provider-adapter.sh sources provider-adapter-version.sh"
else
  fail "provider-adapter.sh does not source provider-adapter-version.sh"
fi

# ---------------------------------------------------------------------------
# 2. Doc ## Contract version agrees with HQ_ADAPTER_CONTRACT_VERSION
# ---------------------------------------------------------------------------
doc_ver="$(awk '
  /^## Contract version/ { grab=1; next }
  grab && /^## / { exit }
  grab && $0 ~ /[0-9]+\.[0-9]+\.[0-9]+/ {
    if (match($0, /[0-9]+\.[0-9]+(\.[0-9]+)?([-.][0-9A-Za-z.]+)?/)) {
      print substr($0, RSTART, RLENGTH)
      exit
    }
  }
' "$DOC")"
if [[ "$doc_ver" == "$HQ_ADAPTER_CONTRACT_VERSION" ]]; then
  pass "doc contract version matches ($doc_ver)"
else
  fail "doc version '$doc_ver' != HQ_ADAPTER_CONTRACT_VERSION '$HQ_ADAPTER_CONTRACT_VERSION'"
fi

# ---------------------------------------------------------------------------
# 3. Unknown provider: exit 1, message, no adapter file sourced
# ---------------------------------------------------------------------------
mkdir -p "$TMP/adapters-unknown"
# Marker file that would set a canary if sourced under a wrong name path.
printf 'CANARY_SOURCED=1\n' > "$TMP/adapters-unknown/gemini.sh"
export HQ_ADAPTER_DIR="$TMP/adapters-unknown"
unset CANARY_SOURCED 2>/dev/null || true
set +e
err="$(hq_adapter_load gemini 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 1 ]] && [[ "$err" == *"unknown provider: gemini"* ]]; then
  pass "unknown provider gemini exits 1"
else
  fail "unknown provider: rc=$rc err=$err"
fi
if [[ -z "${CANARY_SOURCED:-}" ]]; then
  pass "unknown provider did not source adapter file"
else
  fail "unknown provider sourced an adapter file (CANARY_SOURCED set)"
fi

# ---------------------------------------------------------------------------
# 4. Incomplete stub: only hq_adapter_id → missing capabilities message + restore
# ---------------------------------------------------------------------------
mkdir -p "$TMP/adapters-incomplete"
cat > "$TMP/adapters-incomplete/codex.sh" <<'STUB'
hq_adapter_id() { printf 'codex\n'; }
STUB
export HQ_ADAPTER_DIR="$TMP/adapters-incomplete"
set +e
err="$(hq_adapter_load codex 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 1 ]] && [[ "$err" == *"adapter contract violation: codex missing hq_adapter_capabilities"* ]]; then
  pass "incomplete stub reports missing hq_adapter_capabilities"
else
  fail "incomplete stub: rc=$rc err=$err"
fi
# Partially loaded functions must not remain — defaults restored.
id_out="$(hq_adapter_id 2>&1)" || true
if [[ "$id_out" == *"no provider loaded"* ]]; then
  pass "defaults restored after incomplete load"
else
  fail "partial load left non-default hq_adapter_id: $id_out"
fi

# ---------------------------------------------------------------------------
# 5. Conforming stub: capabilities shape + enum rejection in test harness
# ---------------------------------------------------------------------------
mkdir -p "$TMP/adapters-ok"
cat > "$TMP/adapters-ok/claude.sh" <<'STUB'
hq_adapter_id() { printf 'claude\n'; }
hq_adapter_capabilities() {
  cat <<'CAPS'
system_prompt=native
resume=emulated
hooks=native
plan_mode=absent
durable_writes=emulated
telegram_eligible=no
usage_source=transcript
CAPS
}
hq_adapter_build_invocation() {
  if [[ $# -ne 3 ]]; then
    echo "hq_adapter_build_invocation: requires <task_file> <workdir> <preflight on|off>" >&2
    return 1
  fi
  local task="$1" workdir="$2" preflight="$3"
  case "$preflight" in on|off) ;; *) echo "bad preflight" >&2; return 1 ;; esac
  # Path only — never cat the task file into the command.
  printf 'cd %s && provider-stub --task %s --preflight %s\n' "$workdir" "$task" "$preflight"
}
hq_adapter_extract_reply() { cat; }
hq_adapter_emit_usage() { printf 'usage_source=transcript\n'; }
STUB

export HQ_ADAPTER_DIR="$TMP/adapters-ok"
if hq_adapter_load claude; then
  pass "conforming stub loads"
else
  fail "conforming stub failed to load"
fi

caps="$(hq_adapter_capabilities)"
expected_keys=(system_prompt resume hooks plan_mode durable_writes telegram_eligible usage_source)
line_count="$(printf '%s\n' "$caps" | grep -c '=' || true)"
if [[ "$line_count" -eq 7 ]]; then
  pass "capabilities has 7 key=value lines"
else
  fail "capabilities line count=$line_count (want 7)"
fi
for k in "${expected_keys[@]}"; do
  if printf '%s\n' "$caps" | grep -q "^${k}="; then
    pass "capabilities has $k"
  else
    fail "capabilities missing key $k"
  fi
done

# Enum validation helper (what the contract test enforces on stub output).
_validate_caps_enums() {
  local body="$1" k v
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    k="${line%%=*}"
    v="${line#*=}"
    case "$k" in
      system_prompt|resume|hooks|plan_mode|durable_writes)
        case "$v" in native|emulated|absent) ;; *)
          echo "bad enum $k=$v"; return 1 ;; esac
        ;;
      telegram_eligible)
        case "$v" in yes|no) ;; *)
          echo "bad enum $k=$v"; return 1 ;; esac
        ;;
      usage_source)
        case "$v" in transcript|cli|unavailable) ;; *)
          echo "bad enum $k=$v"; return 1 ;; esac
        ;;
      *)
        echo "unknown key $k"; return 1
        ;;
    esac
  done <<< "$body"
  return 0
}

if _validate_caps_enums "$caps"; then
  pass "conforming stub enums valid"
else
  fail "conforming stub enums invalid: $caps"
fi

# Stub declaring usage_source=tokens must fail the enum check.
bad_caps="$(printf '%s\n' "$caps" | sed 's/^usage_source=.*/usage_source=tokens/')"
set +e
bad_msg="$(_validate_caps_enums "$bad_caps" 2>&1)"
bad_rc=$?
set -e
if [[ "$bad_rc" -ne 0 ]] && [[ "$bad_msg" == *"usage_source=tokens"* ]]; then
  pass "usage_source=tokens rejected by enum check"
else
  fail "usage_source=tokens should fail enum check (rc=$bad_rc msg=$bad_msg)"
fi

# ---------------------------------------------------------------------------
# 6. build_invocation: arity + prompt-by-file
# ---------------------------------------------------------------------------
task_file="$TMP/task-prompt.txt"
printf 'SECRET_PROMPT_BYTES_42\n' > "$task_file"

set +e
err="$(hq_adapter_build_invocation "$task_file" /tmp/workdir 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  pass "build_invocation with 2 args exits non-zero"
else
  fail "build_invocation with 2 args should fail (got rc=0 out=$err)"
fi

inv="$(hq_adapter_build_invocation "$task_file" /tmp/workdir on)"
if [[ "$inv" == *"$task_file"* ]] && [[ "$inv" != *"SECRET_PROMPT_BYTES_42"* ]]; then
  pass "build_invocation uses path, not prompt bytes"
else
  fail "prompt-by-file violation or missing path: $inv"
fi

# Deliberately bad stub that interpolates task file contents — contract test fails.
mkdir -p "$TMP/adapters-interp"
cat > "$TMP/adapters-interp/grok.sh" <<'STUB'
hq_adapter_id() { printf 'grok\n'; }
hq_adapter_capabilities() {
  cat <<'CAPS'
system_prompt=absent
resume=absent
hooks=absent
plan_mode=absent
durable_writes=absent
telegram_eligible=no
usage_source=unavailable
CAPS
}
hq_adapter_build_invocation() {
  local task="$1"
  # ILLEGAL: interpolate prompt bytes into the command string.
  printf 'grok -p "$(cat %s)"\n' "$task"
}
hq_adapter_extract_reply() { cat; }
hq_adapter_emit_usage() { :; }
STUB
export HQ_ADAPTER_DIR="$TMP/adapters-interp"
hq_adapter_load grok
interp_task="$TMP/interp-task.txt"
printf 'INTERP_CANARY_99\n' > "$interp_task"
# Expand the way a shell would if the adapter embedded $(cat …) at build time
# by evaluating a second form: adapters that call cat during build_invocation
# embed the bytes in the emitted string. Detect either embedded bytes or a
# "$(cat" substring (today's codex/grok violation pattern).
bad_inv="$(hq_adapter_build_invocation "$interp_task" /tmp off)"
# Force-evaluate a "$(cat path)" form if present, to catch delayed interpolation
# patterns that leave the substitution in the string (still a violation).
if [[ "$bad_inv" == *'$(cat'* ]] || [[ "$bad_inv" == *"INTERP_CANARY_99"* ]]; then
  pass "prompt-by-file detector flags interpolating stub"
else
  fail "expected prompt-by-file violation on interpolating stub: $bad_inv"
fi

# Restore a clean default state for any later assertions.
unset HQ_ADAPTER_DIR
_hq_adapter_install_defaults

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$FAIL" -eq 0 ]]; then
  echo "provider-adapter-contract: all passed"
  exit 0
fi
echo "provider-adapter-contract: $FAIL failed" >&2
exit 1
