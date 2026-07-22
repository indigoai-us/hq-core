#!/usr/bin/env bash
# hq-core: public
# provider-adapter-claude.sh — claude CLI adapter for hq-agent-session.
#
# System prompt: --append-system-prompt "$(cat system.txt)" (native).
# Resume: --resume <sessionId> when HQ_AGENT_SESSION_RESUME_ID is set (matrix).
# Flags parity with claude-runtime.ts:364:
#   --settings, --dangerously-skip-permissions, --permission-mode bypassPermissions
# Never uses --print / headless. User text from user.txt as positional prompt.
# Sets SESSION_SYSTEM_PROMPT_MODE=native.
#
# Render-only mode: HQ_AGENT_SESSION_RENDER_ONLY=1 writes argv to
# <runDir>/provider.argv (NUL-separated) and prints a shell-escaped line to
# <runDir>/provider.argv.txt without exec.
#
# CWD: HQ_SESSION_PROJECT_DIR when set, else company_dir.

provider_adapter_claude() {
  local run_dir="${1:-}" company_dir="${2:-}"
  local system_file="$run_dir/system.txt"
  local user_file="$run_dir/user.txt"
  local settings_file="$run_dir/settings.json"
  local system_text user_text resume_id cwd
  local -a argv

  [ -f "$system_file" ] || { echo "hq-agent-session: missing system.txt" >&2; return 1; }
  [ -f "$user_file" ] || { echo "hq-agent-session: missing user.txt" >&2; return 1; }

  system_text="$(cat "$system_file")"
  user_text="$(cat "$user_file")"
  resume_id="${HQ_AGENT_SESSION_RESUME_ID:-}"

  # Minimal settings so --settings has a target (tests / dry runs).
  if [ ! -f "$settings_file" ]; then
    printf '%s\n' '{}' > "$settings_file"
  fi

  argv=(
    claude
    --settings "$settings_file"
    --dangerously-skip-permissions
    --permission-mode bypassPermissions
    --append-system-prompt "$system_text"
  )
  if [ -n "$resume_id" ]; then
    argv+=(--resume "$resume_id")
  fi
  argv+=(
    --
    "$user_text"
  )

  SESSION_SYSTEM_PROMPT_MODE="native"
  SESSION_RESUME_SUPPORTED="true"
  _provider_write_argv "$run_dir" "${argv[@]}"

  if [ "${HQ_AGENT_SESSION_RENDER_ONLY:-0}" = "1" ]; then
    return 0
  fi

  cwd="${HQ_SESSION_PROJECT_DIR:-${company_dir:?company dir required}}"
  (
    cd "$cwd" || exit 1
    "${argv[@]}"
  )
}

# _provider_write_argv <runDir> <args...>
_provider_write_argv() {
  local run_dir="$1"
  shift
  local f_nul="$run_dir/provider.argv"
  local f_txt="$run_dir/provider.argv.txt"
  : > "$f_nul"
  : > "$f_txt"
  local a first=1
  for a in "$@"; do
    printf '%s\0' "$a" >> "$f_nul"
    if [ "$first" -eq 1 ]; then
      printf '%s' "$a" >> "$f_txt"
      first=0
    else
      # shell-escape for fixture comparison of non-multiline short args;
      # multiline values are represented as $'...'
      case "$a" in
        *$'\n'*|*$'\t'*|*\'*)
          printf " \$'%s'" "$(printf '%s' "$a" | sed -e "s/'/'\\\\''/g")" >> "$f_txt"
          ;;
        *' '*|*'|'*)
          printf " '%s'" "$a" >> "$f_txt"
          ;;
        *)
          printf ' %s' "$a" >> "$f_txt"
          ;;
      esac
    fi
  done
  printf '\n' >> "$f_txt"
  # Also write one-arg-per-line form (escaped) for stable fixtures.
  local f_lines="$run_dir/provider.argv.lines"
  : > "$f_lines"
  for a in "$@"; do
    printf '%s\n' "$a" >> "$f_lines"
  done
}
