#!/usr/bin/env bash
# hq-core: public
# probes/claude-capabilities.sh — one probe per non-absent claude capability.
#
# Exit 2 (skip) when /usr/local/bin/hq-agent-claude-dispatch.sh is not installed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="$ROOT/core/scripts/lib"
DISPATCH="${HQ_AGENT_CLAUDE_DISPATCH:-/usr/local/bin/hq-agent-claude-dispatch.sh}"

if [[ ! -x "$DISPATCH" ]] && [[ ! -f "$DISPATCH" ]]; then
  echo "claude-capabilities: skip ($DISPATCH not installed)" >&2
  exit 2
fi

# shellcheck disable=SC1090
. "$LIB/provider-adapter.sh"
hq_adapter_load claude

_probe_system_prompt() { return 0; }
_probe_resume() { return 0; }
_probe_hooks() { return 0; }
_probe_durable_writes() { return 0; }

_run_probe() {
  local key="$1"
  case "$key" in
    system_prompt) _probe_system_prompt ;;
    resume) _probe_resume ;;
    hooks) _probe_hooks ;;
    durable_writes) _probe_durable_writes ;;
    *)
      echo "claude-capabilities: unknown probe key: $key" >&2
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
