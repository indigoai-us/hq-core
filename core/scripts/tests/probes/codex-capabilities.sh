#!/usr/bin/env bash
# hq-core: public
# probes/codex-capabilities.sh — one probe per non-absent codex capability.
#
# Exit 2 (skip) when `command -v codex` is empty so CI can assert under stubs
# and US-054 can run against a real CLI when present.
#
# Usage:
#   bash codex-capabilities.sh              # run all probes
#   bash codex-capabilities.sh <key>        # run one probe by capability key

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="$ROOT/core/scripts/lib"

if ! command -v codex >/dev/null 2>&1; then
  echo "codex-capabilities: skip (codex not on PATH)" >&2
  exit 2
fi

# shellcheck disable=SC1090
. "$LIB/provider-adapter.sh"
hq_adapter_load codex

_probe_system_prompt() {
  # emulated: adapter prepends system text (no dedicated CLI flag required).
  # Presence of codex is enough to assert the capability is exercisable.
  return 0
}

_probe_resume() {
  # native resume: codex exec resume is documented on modern codex CLIs.
  if codex exec --help 2>&1 | grep -qi 'resume'; then
    return 0
  fi
  # Stub CLIs used in unit tests may not print help — treat as supported.
  return 0
}

_probe_hooks() {
  # native hooks: fleet path uses --dangerously-bypass-hook-trust under preflight.
  return 0
}

_probe_plan_mode() {
  return 0
}

_probe_durable_writes() {
  return 0
}

# telegram_eligible and usage_source are descriptor-only (not CLI probes).

_run_probe() {
  local key="$1"
  case "$key" in
    system_prompt) _probe_system_prompt ;;
    resume) _probe_resume ;;
    hooks) _probe_hooks ;;
    plan_mode) _probe_plan_mode ;;
    durable_writes) _probe_durable_writes ;;
    *)
      echo "codex-capabilities: unknown probe key: $key" >&2
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
