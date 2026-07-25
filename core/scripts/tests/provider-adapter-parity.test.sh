#!/usr/bin/env bash
# hq-core: public
# provider-adapter-parity.test.sh - US-504 cross-provider conformance.
#
# WHAT THIS PROVES. Every provider in HQ_ADAPTER_PROVIDERS satisfies ONE
# contract: all five functions, all seven descriptor keys with legal values,
# prompt-by-file in both preflight modes.
#
# WHAT THIS DELIBERATELY DOES NOT DO. It does not demand the three providers
# have IDENTICAL capabilities. codex declares plan_mode=native while grok and
# claude declare absent; claude declares resume=emulated while the others
# declare native. A test asserting sameness would be permanently red, or would
# pressure someone into declaring a capability the provider does not have --
# which is worse than divergence, because the control plane would then route
# work to a provider that cannot do it. Divergence is REPORTED as a matrix and
# exits 0. Only an UNDECLARED key or an ILLEGAL value fails the build.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$ROOT/core/scripts/lib"
ADAPTER_SH="$LIB/provider-adapter.sh"
ADAPTER_DIR="$LIB/provider-adapters"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Stub CLIs on PATH (AC1). The renders are pure string construction, but a
# provider is entitled to probe for its binary, so the stubs keep this test
# honest without invoking a real model.
mkdir -p "$TMP/bin"
for stub in codex grok claude; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/$stub"
  chmod +x "$TMP/bin/$stub"
done
PATH="$TMP/bin:$PATH"
export PATH

# shellcheck disable=SC1090
. "$ADAPTER_SH"

REQUIRED_FNS=(
  hq_adapter_id
  hq_adapter_capabilities
  hq_adapter_build_invocation
  hq_adapter_extract_reply
  hq_adapter_emit_usage
)

CAPABILITY_KEYS=(
  system_prompt
  resume
  hooks
  plan_mode
  durable_writes
  telegram_eligible
  usage_source
)

# Enums fixed in US-050 (core/docs/hq/provider-adapter-contract.md).
_legal_values_for() {
  case "$1" in
    system_prompt|resume|hooks|plan_mode|durable_writes) echo "native emulated absent" ;;
    telegram_eligible)                                   echo "yes no" ;;
    usage_source)                                        echo "transcript cli unavailable" ;;
    *)                                                   echo "" ;;
  esac
}

_lookup() {
  local key="$1" descriptor="$2" line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "${line%%=*}" == "$key" ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <<EOF
$descriptor
EOF
  return 0
}

# _model_argv <command> - the model-invocation segment of a rendered command.
#
# AC3 excludes the grok key-file preamble BY POSITION, not by provider name.
# Every render is a `&&`-joined chain whose LAST segment invokes the model:
#   codex:  cd <wd> && codex exec ... <taskfile>
#   grok:   cd <wd> && K="$(cat <keyfile>)" && export ... && grok -p <taskfile>
#   claude: cd <wd> && VAR=... <dispatch wrapper>
# Taking the last segment therefore drops `cd` and any credential preamble
# without ever naming a provider -- a fourth provider with its own preamble is
# handled identically.
_model_argv() {
  local cmd="$1"
  printf '%s' "${cmd##*&& }"
}

PROVIDERS_SEEN=0
MISSING_ADAPTER=0

for provider in $HQ_ADAPTER_PROVIDERS; do
  PROVIDERS_SEEN=$((PROVIDERS_SEEN + 1))

  # AC1: a listed provider with no adapter file breaks the build.
  if [[ ! -f "$ADAPTER_DIR/${provider}.sh" ]]; then
    fail "parity: $provider listed in HQ_ADAPTER_PROVIDERS but has no adapter file"
    MISSING_ADAPTER=1
    continue
  fi

  if ! hq_adapter_load "$provider" >/dev/null 2>&1; then
    fail "parity: $provider failed hq_adapter_load"
    continue
  fi

  # AC1: all five contract functions defined.
  missing_fn=0
  for fn in "${REQUIRED_FNS[@]}"; do
    declare -F "$fn" >/dev/null 2>&1 || { fail "parity: $provider missing $fn"; missing_fn=1; }
  done
  [[ "$missing_fn" -eq 0 ]] && pass "$provider defines all five contract functions"

  # AC2: seven descriptor keys, each with a legal value.
  descriptor="$(hq_adapter_capabilities)"
  cap_ok=1
  for key in "${CAPABILITY_KEYS[@]}"; do
    value="$(_lookup "$key" "$descriptor")"
    if [[ -z "$value" ]]; then
      fail "parity: $provider missing capability $key"
      cap_ok=0
      continue
    fi
    legal="$(_legal_values_for "$key")"
    found=0
    for allowed in $legal; do
      [[ "$value" == "$allowed" ]] && { found=1; break; }
    done
    if [[ "$found" -ne 1 ]]; then
      fail "parity: $provider illegal value $value for $key"
      cap_ok=0
    fi
  done
  [[ "$cap_ok" -eq 1 ]] && pass "$provider declares all seven capability keys legally"

  # AC1 + AC3: both preflight modes render, prompt-by-file, no inline cat.
  task="$TMP/task.txt"
  : > "$task"
  for mode in on off; do
    if [[ "$mode" == "on" ]]; then
      wd='"${HQ_AGENT_COMPANY_DIR:?session preflight company missing}"'
    else
      wd="/home/ec2-user/hq"
    fi

    if ! cmd="$(hq_adapter_build_invocation "$task" "$wd" "$mode" 2>/dev/null)"; then
      fail "parity: $provider build_invocation returned non-zero (preflight $mode)"
      continue
    fi
    if [[ -z "$cmd" ]]; then
      fail "parity: $provider emitted an empty command (preflight $mode)"
      continue
    fi

    argv="$(_model_argv "$cmd")"
    if [[ "$argv" != *"$task"* ]]; then
      fail "parity: $provider model argv does not reference the task file (preflight $mode)"
      continue
    fi
    if [[ "$argv" == *'$(cat'* ]]; then
      fail "parity: $provider inlines the prompt with \$(cat in the model argv (preflight $mode)"
      continue
    fi
    pass "$provider renders prompt-by-file (preflight $mode)"
  done
done

if [[ "$PROVIDERS_SEEN" -eq 0 ]]; then
  fail "parity: HQ_ADAPTER_PROVIDERS is empty"
fi

# ---------------------------------------------------------------------------
# AC4: report divergence as a matrix. This is stdout, not an assertion.
# ---------------------------------------------------------------------------
if [[ "$MISSING_ADAPTER" -eq 0 ]]; then
  echo
  echo "capability matrix (divergence is reported, not failed):"
  printf '  %-18s' "key"
  for provider in $HQ_ADAPTER_PROVIDERS; do printf '%-14s' "$provider"; done
  printf '\n'
  printf '  %-18s' "---"
  for provider in $HQ_ADAPTER_PROVIDERS; do printf '%-14s' "---"; done
  printf '\n'
  for key in "${CAPABILITY_KEYS[@]}"; do
    printf '  %-18s' "$key"
    for provider in $HQ_ADAPTER_PROVIDERS; do
      hq_adapter_load "$provider" >/dev/null 2>&1 || { printf '%-14s' "?"; continue; }
      printf '%-14s' "$(_lookup "$key" "$(hq_adapter_capabilities)")"
    done
    printf '\n'
  done
  echo
fi

if [[ "$FAIL" -gt 0 ]]; then
  echo "provider-adapter-parity: $FAIL failure(s)" >&2
  exit 1
fi
echo "provider-adapter-parity: all passed"
