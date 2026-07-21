#!/usr/bin/env bash
# hq-core: public
# provider-adapter-grok.sh — grok CLI adapter for hq-agent-session.
#
# System prompt: --system-prompt-override "$(cat system.txt)" (native).
# Keeps --yolo (and --no-auto-update) from user-data.ts fleet invocation.
# User text from user.txt via -p (single-turn). Never concatenates system
# text into the positional prompt argument.
# Sets SESSION_SYSTEM_PROMPT_MODE=native.

provider_adapter_grok() {
  local run_dir="${1:-}" company_dir="${2:-}"
  local system_file="$run_dir/system.txt"
  local user_file="$run_dir/user.txt"
  local system_text user_text
  local -a argv

  [ -f "$system_file" ] || { echo "hq-agent-session: missing system.txt" >&2; return 1; }
  [ -f "$user_file" ] || { echo "hq-agent-session: missing user.txt" >&2; return 1; }

  system_text="$(cat "$system_file")"
  user_text="$(cat "$user_file")"

  argv=(
    grok
    -p
    "$user_text"
    --yolo
    --no-auto-update
    --system-prompt-override
    "$system_text"
  )

  SESSION_SYSTEM_PROMPT_MODE="native"

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
  printf 'cli-flag:--system-prompt-override\n' > "$run_dir/provider.systemPromptMechanism"

  if [ "${HQ_AGENT_SESSION_RENDER_ONLY:-0}" = "1" ]; then
    return 0
  fi

  (
    cd "${company_dir:?company dir required}" || exit 1
    "${argv[@]}"
  )
}
