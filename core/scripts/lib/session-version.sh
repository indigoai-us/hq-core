#!/usr/bin/env bash
# hq-core: public
# session-version.sh — contract version admission for hq-agent-session.
#
# Sourced by core/scripts/hq-agent-session.sh. Never hardcodes the supported
# version: reads agentSessionContractVersion from <root>/core/core.yaml
# (absent key → 1).

# session_supported_contract_version <root>
#   Print the integer supported contract version from core/core.yaml.
session_supported_contract_version() {
  local root="${1:-}"
  local yaml="$root/core/core.yaml"
  local ver=""
  if [ -f "$yaml" ]; then
    ver="$(awk '
      /^[[:space:]]*agentSessionContractVersion:[[:space:]]*/ {
        sub(/^[[:space:]]*agentSessionContractVersion:[[:space:]]*/, "")
        gsub(/[[:space:]]+#.*$/, "")
        gsub(/[[:space:]]/, "")
        gsub(/["'\'']/, "")
        print
        exit
      }
    ' "$yaml")"
  fi
  case "$ver" in
    ''|*[!0-9]*) printf '1' ;;
    *) printf '%s' "$ver" ;;
  esac
}

# session_admit_contract_version <root> <requestVersion>
#   Exit 5 when request > supported (caller emits CONTRACT_VERSION_TOO_NEW).
#   Sets SESSION_SUPPORTED_VERSION and SESSION_CONTRACT_DOWNGRADE (0|1).
session_admit_contract_version() {
  local root="${1:-}" req="${2:-}"
  local supported
  supported="$(session_supported_contract_version "$root")"
  SESSION_SUPPORTED_VERSION="$supported"
  SESSION_CONTRACT_DOWNGRADE=0

  case "$req" in
    ''|*[!0-9]*)
      echo "hq-agent-session: invalid contractVersion: $req" >&2
      return 5
      ;;
  esac

  if [ "$req" -gt "$supported" ]; then
    echo "hq-agent-session: CONTRACT_VERSION_TOO_NEW request=$req supported=$supported" >&2
    return 5
  fi
  if [ "$req" -lt "$supported" ]; then
    SESSION_CONTRACT_DOWNGRADE=1
  fi
  return 0
}
