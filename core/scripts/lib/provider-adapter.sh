#!/usr/bin/env bash
# hq-core: public
# provider-adapter.sh — provider adapter contract (US-500) + session dispatch.
#
# Contract surface (source this file):
#   HQ_ADAPTER_PROVIDERS            — "codex grok claude"
#   HQ_ADAPTER_CONTRACT_VERSION     — from provider-adapter-version.sh
#   hq_adapter_load <provider>      — source provider-adapters/<provider>.sh
#   hq_adapter_id / capabilities / build_invocation / extract_reply / emit_usage
#
# Session surface (hq-agent-session, separate from the fleet contract):
#   session_provider_dispatch <provider> <runDir> <companyDir>
#   Exit 4 for unsupported provider.

# ---------------------------------------------------------------------------
# Contract version — single source in provider-adapter-version.sh
# ---------------------------------------------------------------------------
_hq_adapter_lib_dir() {
  # BASH_SOURCE[0] is this file when sourced or executed.
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# shellcheck source=provider-adapter-version.sh
. "$(_hq_adapter_lib_dir)/provider-adapter-version.sh"

# Single provider list. hq_adapter_load is fail-closed for anything else.
export HQ_ADAPTER_PROVIDERS="codex grok claude"

# Required function names every provider adapter must define.
HQ_ADAPTER_REQUIRED_FNS=(
  hq_adapter_id
  hq_adapter_capabilities
  hq_adapter_build_invocation
  hq_adapter_extract_reply
  hq_adapter_emit_usage
)

# ---------------------------------------------------------------------------
# Default (no-provider) stubs — present after source so declare -F succeeds.
# Restored on hq_adapter_load contract violation.
# ---------------------------------------------------------------------------
_hq_adapter_install_defaults() {
  hq_adapter_id() {
    echo "adapter contract violation: no provider loaded" >&2
    return 1
  }

  hq_adapter_capabilities() {
    echo "adapter contract violation: no provider loaded" >&2
    return 1
  }

  # Exactly three args: task file PATH, workdir expression, preflight on|off.
  # Defaults enforce arity even before a provider is loaded.
  hq_adapter_build_invocation() {
    if [[ $# -ne 3 ]]; then
      echo "hq_adapter_build_invocation: requires <task_file> <workdir> <preflight on|off>" >&2
      return 1
    fi
    local preflight="${3:-}"
    case "$preflight" in
      on|off) ;;
      *)
        echo "hq_adapter_build_invocation: preflight mode must be on|off (got: ${preflight:-<empty>})" >&2
        return 1
        ;;
    esac
    echo "adapter contract violation: no provider loaded" >&2
    return 1
  }

  hq_adapter_extract_reply() {
    echo "adapter contract violation: no provider loaded" >&2
    return 1
  }

  hq_adapter_emit_usage() {
    echo "adapter contract violation: no provider loaded" >&2
    return 1
  }
}

_hq_adapter_install_defaults

# hq_adapter_load <provider>
#   Sources core/scripts/lib/provider-adapters/<provider>.sh (or
#   $HQ_ADAPTER_DIR/<provider>.sh when set). Verifies all five required
#   functions are defined. Fail-closed on unknown provider or missing fn.
hq_adapter_load() {
  local provider="${1:-}"
  local lib_dir adapter_dir adapter_file fn known=0 p

  if [[ -z "$provider" ]]; then
    echo "unknown provider: " >&2
    return 1
  fi

  for p in $HQ_ADAPTER_PROVIDERS; do
    if [[ "$p" == "$provider" ]]; then
      known=1
      break
    fi
  done
  if [[ "$known" -ne 1 ]]; then
    echo "unknown provider: $provider" >&2
    return 1
  fi

  lib_dir="$(_hq_adapter_lib_dir)"
  adapter_dir="${HQ_ADAPTER_DIR:-$lib_dir/provider-adapters}"
  adapter_file="$adapter_dir/${provider}.sh"

  if [[ ! -f "$adapter_file" ]]; then
    echo "adapter contract violation: $provider missing adapter file" >&2
    _hq_adapter_install_defaults
    return 1
  fi

  # Drop any previously loaded provider symbols before sourcing so a failed
  # load cannot leave a mixed set of functions in scope.
  for fn in "${HQ_ADAPTER_REQUIRED_FNS[@]}"; do
    unset -f "$fn" 2>/dev/null || true
  done

  # shellcheck disable=SC1090
  # Provider files are not known at lint time (loaded by id).
  if ! . "$adapter_file"; then
    echo "adapter contract violation: $provider failed to source" >&2
    _hq_adapter_install_defaults
    return 1
  fi

  for fn in "${HQ_ADAPTER_REQUIRED_FNS[@]}"; do
    if ! declare -F "$fn" >/dev/null 2>&1; then
      echo "adapter contract violation: $provider missing $fn" >&2
      _hq_adapter_install_defaults
      return 1
    fi
  done

  return 0
}

# ---------------------------------------------------------------------------
# Session dispatch (hq-agent-session) — separate from the fleet contract above.
# ---------------------------------------------------------------------------
session_provider_dispatch() {
  local provider="${1:-}" run_dir="${2:-}" company_dir="${3:-}"
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  case "$provider" in
    claude)
      # shellcheck source=provider-adapter-claude.sh
      . "$lib_dir/provider-adapter-claude.sh"
      provider_adapter_claude "$run_dir" "$company_dir"
      ;;
    codex)
      # shellcheck source=provider-adapter-codex.sh
      . "$lib_dir/provider-adapter-codex.sh"
      provider_adapter_codex "$run_dir" "$company_dir"
      ;;
    grok)
      # shellcheck source=provider-adapter-grok.sh
      . "$lib_dir/provider-adapter-grok.sh"
      provider_adapter_grok "$run_dir" "$company_dir"
      ;;
    *)
      echo "hq-agent-session: unsupported provider: ${provider:-<empty>}" >&2
      return 4
      ;;
  esac
}
