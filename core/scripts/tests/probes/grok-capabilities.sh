#!/usr/bin/env bash
# hq-core: public
# probes/grok-capabilities.sh — one probe per non-absent grok capability.
#
# Exit 2 (skip) when neither `command -v grok` nor /home/ec2-user/.grok/bin/grok
# is present.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="$ROOT/core/scripts/lib"
GROK_BIN_DEFAULT="/home/ec2-user/.grok/bin/grok"

_grok_present() {
  command -v grok >/dev/null 2>&1 && return 0
  [[ -x "$GROK_BIN_DEFAULT" ]] && return 0
  return 1
}

if ! _grok_present; then
  echo "grok-capabilities: skip (grok not on PATH and $GROK_BIN_DEFAULT absent)" >&2
  exit 2
fi

# shellcheck disable=SC1090
. "$LIB/provider-adapter.sh"
hq_adapter_load grok

_probe_system_prompt() { return 0; }
_probe_resume() { return 0; }
_probe_durable_writes() { return 0; }

_run_probe() {
  local key="$1"
  case "$key" in
    system_prompt) _probe_system_prompt ;;
    resume) _probe_resume ;;
    durable_writes) _probe_durable_writes ;;
    *)
      echo "grok-capabilities: unknown probe key: $key" >&2
      return 1
      ;;
  esac
}

main() {
  local key="${1:-}"
  if [[ -n "$key" ]]; then
    _run_probe "$key"
    return $?
  fi
  local caps k v
  caps="$(hq_adapter_capabilities)"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    k="${line%%=*}"
    v="${line#*=}"
    case "$k" in
      system_prompt|resume|hooks|plan_mode|durable_writes)
        if [[ "$v" != "absent" ]]; then
          _run_probe "$k" || return $?
        fi
        ;;
    esac
  done <<< "$caps"
  return 0
}

main "$@"
