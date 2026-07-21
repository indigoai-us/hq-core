#!/usr/bin/env bash
# hq-core: public
# provider-adapter.sh — dispatch to claude/codex/grok adapters for hq-agent-session.
#
# Usage (sourced):
#   session_provider_dispatch <provider> <runDir> <companyDir>
# Exit 4 for unsupported provider.

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
