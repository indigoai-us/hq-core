#!/usr/bin/env bash
# hq-core: public
# provider-adapter-codex.sh — codex CLI adapter for hq-agent-session.
#
# Determination (codex-cli 0.144.6, `codex exec --help`): no dedicated
# system-prompt flag or instructions-file option. Mechanism = none.
# Fallback: prepend system.txt to the positional prompt and set
# systemPromptMode=prepended (never silent).
#
# Invocation parity with resolveRunAgentInner:
#   codex exec --skip-git-repo-check --dangerously-bypass-hook-trust <prompt>

provider_adapter_codex() {
  local run_dir="${1:-}" company_dir="${2:-}"
  local system_file="$run_dir/system.txt"
  local user_file="$run_dir/user.txt"
  local system_text user_text prompt
  local -a argv

  [ -f "$system_file" ] || { echo "hq-agent-session: missing system.txt" >&2; return 1; }
  [ -f "$user_file" ] || { echo "hq-agent-session: missing user.txt" >&2; return 1; }

  system_text="$(cat "$system_file")"
  user_text="$(cat "$user_file")"

  # Mechanism: none → prepend system text; positional prompt must still not
  # be ONLY system text without a separator so capture stays auditable.
  prompt="$(printf '%s\n\n%s' "$system_text" "$user_text")"
  SESSION_SYSTEM_PROMPT_MODE="prepended"

  argv=(
    codex
    exec
    --skip-git-repo-check
    --dangerously-bypass-hook-trust
    --
    "$prompt"
  )

  # Reuse write helper from claude adapter if loaded; else define minimal.
  if ! command -v _provider_write_argv >/dev/null 2>&1; then
    _provider_write_argv() {
      local rd="$1"; shift
      local f_lines="$rd/provider.argv.lines"
      : > "$f_lines"
      local a
      for a in "$@"; do printf '%s\n' "$a" >> "$f_lines"; done
      # Also NUL form
      : > "$rd/provider.argv"
      for a in "$@"; do printf '%s\0' "$a" >> "$rd/provider.argv"; done
    }
  fi
  _provider_write_argv "$run_dir" "${argv[@]}"

  # Record mechanism for envelope consumers.
  printf 'none\n' > "$run_dir/provider.systemPromptMechanism"

  if [ "${HQ_AGENT_SESSION_RENDER_ONLY:-0}" = "1" ]; then
    return 0
  fi

  (
    cd "${company_dir:?company dir required}" || exit 1
    "${argv[@]}"
  )
}
