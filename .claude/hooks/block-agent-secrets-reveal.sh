#!/usr/bin/env bash
# Block secret-value reveal in agent tool commands when hq-flags enables it.
# Missing or unavailable flag data keeps the default-off reveal behavior.
set -uo pipefail

INPUT="$(cat 2>/dev/null || printf '{}')"
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$TOOL_NAME" = "Bash" ] || exit 0
COMMAND_TEXT="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$COMMAND_TEXT" ] || exit 0

HOOK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)" || exit 0
. "$HOOK_ROOT/core/scripts/hook-lib.sh"

# Return 0 when an argv vector can invoke the secret-reveal command. Parse only
# the top-level command shape; shell text, wrappers and child commands are
# recursively inspected without evaluating any submitted code.
inspect_command_string() {
  local text="$1" depth="${2:-0}" records record
  if [ "$depth" -gt 12 ]; then
    case "$text" in *secrets*|*reveal*) return 0 ;; esac
    return 1
  fi
  records="$(hq_shell_simple_commands "$text" 2>/dev/null)" || return 1
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    local -a parsed_argv=()
    IFS=$'\037' read -r -a parsed_argv <<< "$record"
    inspect_argv "$depth" "${parsed_argv[@]}" && return 0
  done <<< "$records"
  return 1
}

inspect_substitution_tokens() {
  local depth="$1" token inner rest joined="" backtick
  printf -v backtick '\140'
  shift
  for token in "$@"; do
    [ -n "$joined" ] && joined="$joined "
    joined="$joined$token"
    rest="$token"
    while [[ "$rest" =~ \$\(([^()]*)\) ]]; do
      inner="${BASH_REMATCH[1]}"
      inspect_command_string "$inner" "$((depth + 1))" && return 0
      rest="${rest#*\$(}"
      rest="${rest#*)}"
    done
  done
  # The shell lexer intentionally keeps backticks as ordinary characters, so
  # their command body can span multiple argv tokens. Join this simple-command
  # record and inspect complete backtick pairs.
  rest="$joined"
  while [[ "$rest" == *"$backtick"*"$backtick"* ]]; do
    local suffix="${rest#*"$backtick"}"
    inner="${suffix%%"$backtick"*}"
    inspect_command_string "$inner" "$((depth + 1))" && return 0
    rest="${suffix#*"$backtick"}"
  done
  return 1
}

inspect_argv() {
  local depth="$1" i=0 token base executable
  shift
  local -a argv=("$@")
  inspect_substitution_tokens "$depth" "${argv[@]}" && return 0

  # Shell assignment words precede the executable but do not change its argv.
  while [ "$i" -lt "${#argv[@]}" ] && [[ "${argv[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    i=$((i + 1))
  done

  # Unwrap common command prefixes and environment injection. Each wrapper's
  # options and operands are consumed before looking for its child executable.
  while [ "$i" -lt "${#argv[@]}" ]; do
    token="${argv[$i]}"
    base="${token##*/}"
    base="${base%.exe}"; base="${base%.cmd}"
    case "$base" in
      env)
        i=$((i + 1))
        while [ "$i" -lt "${#argv[@]}" ]; do
          token="${argv[$i]}"
          case "$token" in
            --) i=$((i + 1)); break ;;
            -u|--unset|-C|--chdir)
              [ $((i + 1)) -lt "${#argv[@]}" ] || return 1
              i=$((i + 2)) ;;
            -S|--split-string)
              [ $((i + 1)) -lt "${#argv[@]}" ] || return 1
              inspect_command_string "${argv[$((i + 1))]}" "$((depth + 1))" && return 0
              i=$((i + 2)) ;;
            --unset=*|--chdir=*|--split-string=*) i=$((i + 1)) ;;
            -*) i=$((i + 1)) ;;
            [A-Za-z_][A-Za-z0-9_]*=*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      command)
        i=$((i + 1))
        while [ "$i" -lt "${#argv[@]}" ]; do
          case "${argv[$i]}" in
            --) i=$((i + 1)); break ;;
            -p|-v|-V) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      builtin|nohup)
        i=$((i + 1))
        [ "${argv[$i]:-}" = "--" ] && i=$((i + 1))
        ;;
      exec)
        i=$((i + 1))
        while [ "$i" -lt "${#argv[@]}" ]; do
          token="${argv[$i]}"
          case "$token" in
            --) i=$((i + 1)); break ;;
            -a) [ $((i + 1)) -lt "${#argv[@]}" ] || return 1; i=$((i + 2)) ;;
            -a?*) i=$((i + 1)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      sudo)
        i=$((i + 1))
        while [ "$i" -lt "${#argv[@]}" ]; do
          token="${argv[$i]}"
          case "$token" in
            --) i=$((i + 1)); break ;;
            -u|-g|-p|-C|-T|-R|-D|-r|-t|-U|-a|--user|--group|--prompt|--close-from|--command-timeout|--chroot|--chdir|--role|--type|--other-user|--auth-type)
              [ $((i + 1)) -lt "${#argv[@]}" ] || return 1
              i=$((i + 2)) ;;
            -u?*|-g?*|-p?*|-C?*|-T?*|-R?*|-D?*|-r?*|-t?*|-U?*|-a?*|--*=*) i=$((i + 1)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      time)
        i=$((i + 1))
        while [ "$i" -lt "${#argv[@]}" ]; do
          token="${argv[$i]}"
          case "$token" in
            --) i=$((i + 1)); break ;;
            -f|-o|--format|--output)
              [ $((i + 1)) -lt "${#argv[@]}" ] || return 1
              i=$((i + 2)) ;;
            --format=*|--output=*|-a|-p|-v|--append|--portability|--verbose) i=$((i + 1)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      timeout)
        i=$((i + 1))
        while [ "$i" -lt "${#argv[@]}" ]; do
          token="${argv[$i]}"
          case "$token" in
            --) i=$((i + 1)); break ;;
            -k|-s|--kill-after|--signal)
              [ $((i + 1)) -lt "${#argv[@]}" ] || return 1
              i=$((i + 2)) ;;
            --kill-after=*|--signal=*|-v|--verbose|--preserve-status|--foreground) i=$((i + 1)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        # GNU timeout always consumes a duration before the child command.
        [ "$i" -lt "${#argv[@]}" ] || return 1
        i=$((i + 1))
        ;;
      setsid)
        i=$((i + 1))
        while [ "$i" -lt "${#argv[@]}" ]; do
          case "${argv[$i]}" in
            --) i=$((i + 1)); break ;;
            -f|-w|-c|--fork|--wait|--ctty) i=$((i + 1)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "${#argv[@]}" ] || return 1
  executable="${argv[$i]}"
  base="${executable##*/}"
  base="${base%.exe}"; base="${base%.cmd}"
  i=$((i + 1))

  case "$base" in
    bash|sh|dash|zsh|ksh)
      local j script
      for ((j = i; j < ${#argv[@]}; j++)); do
        token="${argv[$j]}"
        case "$token" in
          --) break ;;
          -*c*|-*c) if [ $((j + 1)) -lt "${#argv[@]}" ]; then
            script="${argv[$((j + 1))]}"
            inspect_command_string "$script" "$((depth + 1))" && return 0
            break
          fi ;;
        esac
      done
      ;;
    eval)
      local evaluated=""
      for token in "${argv[@]:$i}"; do
        [ -n "$evaluated" ] && evaluated="$evaluated "
        evaluated="$evaluated$token"
      done
      [ -n "$evaluated" ] && inspect_command_string "$evaluated" "$((depth + 1))" && return 0
      ;;
    npx)
      inspect_npx_argv "$depth" "${argv[@]:$i}" && return 0
      ;;
    hq)
      inspect_hq_argv "$depth" "${argv[@]:$i}" && return 0
      ;;
    secrets)
      inspect_secrets_argv "$depth" "${argv[@]:$i}" && return 0
      ;;
  esac
  return 1
}
inspect_npx_argv() {
  local depth="$1" i=0 token package_name base
  shift
  local -a argv=("$@")
  while [ "$i" -lt "${#argv[@]}" ]; do
    token="${argv[$i]}"
    case "$token" in
      -p|--package) i=$((i + 2)); continue ;;
      -c|--call)
        if [ $((i + 1)) -lt "${#argv[@]}" ]; then
          inspect_command_string "${argv[$((i + 1))]}" "$((depth + 1))" && return 0
        fi
        return 1 ;;
      --package=*) i=$((i + 1)); continue ;;
      -*) i=$((i + 1)); continue ;;
    esac
    package_name="$token"
    base="${package_name##*/}"
    if [[ "$base" =~ ^hq(@.*)?$ ]]; then
      inspect_hq_argv "$depth" "${argv[@]:$((i + 1))}" && return 0
    elif [[ "$package_name" =~ ^@indigoai-us/hq-cli(@.*)?$ || "$base" =~ ^hq-cli(@.*)?$ ]]; then
      inspect_hq_argv "$depth" "${argv[@]:$((i + 1))}" && return 0
    fi
    return 1
  done
  return 1
}

inspect_hq_argv() {
  local depth="$1" i token
  shift
  local -a argv=("$@")
  for ((i = 0; i < ${#argv[@]}; i++)); do
    token="${argv[$i]}"
    if [ "$token" = "run" ]; then
      local j
      for ((j = i + 1; j < ${#argv[@]}; j++)); do
        if [ "${argv[$j]}" = "--" ]; then
          inspect_argv "$((depth + 1))" "${argv[@]:$((j + 1))}" && return 0
          break
        fi
      done
      return 1
    fi
    if [ "$token" = "secrets" ]; then
      inspect_secrets_argv "$depth" "${argv[@]:$((i + 1))}" && return 0
      return 1
    fi
  done
  return 1
}

inspect_secrets_argv() {
  local depth="$1" i token found_get=0 found_reveal=0
  shift
  local -a argv=("$@")
  for ((i = 0; i < ${#argv[@]}; i++)); do
    token="${argv[$i]}"
    case "$token" in
      reveal) found_reveal=1 ;;
      get) found_get=1 ;;
      exec)
        local j
        for ((j = i + 1; j < ${#argv[@]}; j++)); do
          if [ "${argv[$j]}" = "--" ]; then
            inspect_argv "$((depth + 1))" "${argv[@]:$((j + 1))}" && return 0
            break
          fi
        done
        return 1 ;;
    esac
  done
  if [ "$found_reveal" = 1 ]; then return 0; fi
  [ "$found_get" = 1 ] || return 1
  for token in "${argv[@]}"; do
    case "$token" in --reveal|--reveal=*) return 0 ;; esac
  done
  return 1
}

# Skip flag lookup for unrelated commands so lookup diagnostics stay scoped to reveal attempts.
if ! inspect_command_string "$COMMAND_TEXT"; then
  exit 0
fi

# HQ's normal global CLI install carries these hq-flags dependencies. The gate
# helper uses the installed CLI package to load its SDK and cached ID token; it
# never reads or prints credentials itself. Only explicit true in a loaded
# snapshot denies reveal; missing rows and false values stay silent, while
# lookup errors and timeouts allow reveal with one sanitized error-class notice.
HQ_CLI_BIN="$(command -v hq 2>/dev/null || true)"
export HQ_CLI_BIN
FLAG_READER="$HOOK_ROOT/.claude/hooks/block-agent-secrets-reveal-flag.cjs"
FLAG_ENABLED="$(node "$FLAG_READER")" || FLAG_ENABLED=false
[ "$FLAG_ENABLED" = "true" ] || exit 0

MESSAGE='Secret reveal is for humans. Agent sessions must use hq secrets exec --only KEY -- <cmd> or hq run -- <cmd> so secret values stay out of tool output.'
jq -cn --arg reason "$MESSAGE" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
