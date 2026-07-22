#!/usr/bin/env bash
# hq-core: public
# provider-adapter-codex.sh — codex CLI adapter for hq-agent-session.
#
# Determination (codex-cli 0.144.6, `codex exec --help`): no dedicated
# system-prompt flag or instructions-file option. Mechanism = none.
# Fallback: prepend system.txt to the positional prompt and set
# systemPromptMode=prepended (never silent).
#
# Resume (codex-cli 0.144.6, `codex exec resume --help`):
#   codex exec resume [OPTIONS] [SESSION_ID] [PROMPT]
# When HQ_AGENT_SESSION_RESUME_ID is set the adapter inserts the `resume`
# subcommand and the session id before the prompt.
#
# Invocation parity with resolveRunAgentInner:
#   codex exec --skip-git-repo-check --dangerously-bypass-hook-trust <prompt>
#
# CWD: HQ_SESSION_PROJECT_DIR when set, else company_dir.

provider_adapter_codex() {
  local run_dir="${1:-}" company_dir="${2:-}"
  local system_file="$run_dir/system.txt"
  local user_file="$run_dir/user.txt"
  local system_text user_text prompt resume_id cwd
  local -a argv

  [ -f "$system_file" ] || { echo "hq-agent-session: missing system.txt" >&2; return 1; }
  [ -f "$user_file" ] || { echo "hq-agent-session: missing user.txt" >&2; return 1; }

  system_text="$(cat "$system_file")"
  user_text="$(cat "$user_file")"
  resume_id="${HQ_AGENT_SESSION_RESUME_ID:-}"

  # Mechanism: none → prepend system text; positional prompt must still not
  # be ONLY system text without a separator so capture stays auditable.
  prompt="$(printf '%s\n\n%s' "$system_text" "$user_text")"
  SESSION_SYSTEM_PROMPT_MODE="prepended"
  SESSION_RESUME_SUPPORTED="true"

  if [ -n "$resume_id" ]; then
    # Matrix: codex exec resume --skip-git-repo-check --dangerously-bypass-hook-trust <SESSION_ID> -- <prompt>
    argv=(
      codex
      exec
      resume
      --skip-git-repo-check
      --dangerously-bypass-hook-trust
      "$resume_id"
      --
      "$prompt"
    )
  else
    argv=(
      codex
      exec
      --skip-git-repo-check
      --dangerously-bypass-hook-trust
      --
      "$prompt"
    )
  fi

  # Reuse write helper from claude adapter if loaded; else define minimal.
  if ! command -v _provider_write_argv >/dev/null 2>&1; then
    _provider_write_argv() {
      local rd="$1"; shift
      local f_lines="$rd/provider.argv.lines"
      : > "$f_lines"
      local a
      for a in "$@"; do printf '%s\n' "$a" >> "$f_lines"; done
      : > "$rd/provider.argv"
      for a in "$@"; do printf '%s\0' "$a" >> "$rd/provider.argv"; done
    }
  fi
  _provider_write_argv "$run_dir" "${argv[@]}"

  # Record mechanism for envelope consumers.
  if [ -n "$resume_id" ]; then
    printf 'subcommand:exec-resume\n' > "$run_dir/provider.systemPromptMechanism"
  else
    printf 'none\n' > "$run_dir/provider.systemPromptMechanism"
  fi

  if [ "${HQ_AGENT_SESSION_RENDER_ONLY:-0}" = "1" ]; then
    return 0
  fi

  cwd="${HQ_SESSION_PROJECT_DIR:-${company_dir:?company dir required}}"
  (
    cd "$cwd" || exit 1
    "${argv[@]}"
  )
}
