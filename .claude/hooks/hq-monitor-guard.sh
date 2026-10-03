#!/bin/bash
# Gated foreground-wait guard for Claude, Codex, and Grok shell calls.
set -uo pipefail
HOOK_PATH="${BASH_SOURCE[0]:-$0}"
HOOK_DIR="${HOOK_PATH%/*}"
[ "$HOOK_DIR" != "$HOOK_PATH" ] || HOOK_DIR=.
. "$HOOK_DIR/hq-monitor-hook-lib.sh"

payload="$(</dev/stdin)" || payload='{}'
[ "${HQ_LANE_ID+x}" = x ] && exit 0

runtime="${HQ_CHECKPOINT_RUNTIME:-claude}"
parsed_fields="$(printf '%s' "$payload" | jq -jr '
  if type == "object" then
    (.tool_input.run_in_background // .toolInput.run_in_background // false
      | if . == true or . == "true" then "1" else "0" end),
    "\u001f",
    (.tool_input.command // .toolInput.command // "" | tostring),
    "\u001f",
    (.session_id // .sessionId // .tool_input.session_id // .toolInput.session_id // "" | tostring),
    "\u001f"
  else
    "0\u001f\u001f\u001f"
  end
' 2>/dev/null || true)"
run_background="${parsed_fields%%$'\x1f'*}"
parsed_tail="${parsed_fields#*$'\x1f'}"
command_text="${parsed_tail%%$'\x1f'*}"
parsed_tail="${parsed_tail#*$'\x1f'}"
session_id="${parsed_tail%$'\x1f'}"
[ -n "$command_text" ] || exit 0

heredoc_body_is_executable() {
  local line="$1" executable_re='(^|[;&|]|\$\()[[:space:]]*(sudo([[:space:]]+-[^[:space:]]+)*([[:space:]]+[^[:space:]]+)?[[:space:]]+)?(env([[:space:]]+(-[^[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+))*[[:space:]]+)?(xargs([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?(command[[:space:]]+)?([^[:space:]/]+/)*(bash|sh|zsh|dash|ksh|ssh|eval|source)([[:space:]]|$|[|;&])'
  [[ "$line" =~ $executable_re ]]
}

find_heredoc_redirection() {
  local line="$1" quote="" escaped=0 i char previous rest op_width delimiter_match
  HEREDOC_DELIMITER=""
  HEREDOC_STRIP_TABS=0
  for ((i = 0; i < ${#line}; i++)); do
    char="${line:i:1}"
    if [ "$escaped" -eq 1 ]; then
      escaped=0
      continue
    fi
    if [ -n "$quote" ]; then
      if [ "$quote" != "'" ] && [ "$char" = "\\" ]; then escaped=1
      elif [ "$char" = "$quote" ]; then quote=""
      fi
      continue
    fi
    case "$char" in
      "\\") escaped=1; continue ;;
      "'"|'"'|$'\140') quote="$char"; continue ;;
      "#")
        previous=""
        [ "$i" -eq 0 ] || previous="${line:i-1:1}"
        case "$previous" in ""|[[:space:]]|';'|'|'|'&'|'('|')') return 1 ;; esac
        ;;
      "<")
        [ "$((i + 1))" -lt "${#line}" ] || continue
        [ "${line:i+1:1}" = "<" ] || continue
        op_width=2
        while [ "$((i + op_width))" -lt "${#line}" ] && [ "${line:i+op_width:1}" = "<" ]; do
          op_width=$((op_width + 1))
        done
        # A run of three or more '<' characters is a here-string or invalid
        # redirection sequence, never a here-document opener.
        [ "$op_width" -eq 2 ] || { i=$((i + op_width - 1)); continue; }
        rest="${line:i+2}"
        if [[ "$rest" == -* ]]; then
          HEREDOC_STRIP_TABS=1
          rest="${rest:1}"
        fi
        while [[ "$rest" == [[:space:]]* ]]; do rest="${rest:1}"; done
        if [[ "$rest" =~ ^\'([A-Za-z_][A-Za-z0-9_.-]*)\' ]]; then
          delimiter_match="${BASH_REMATCH[1]}"
        elif [[ "$rest" =~ ^\"([A-Za-z_][A-Za-z0-9_.-]*)\" ]]; then
          delimiter_match="${BASH_REMATCH[1]}"
        elif [[ "$rest" =~ ^([A-Za-z_][A-Za-z0-9_.-]*) ]]; then
          delimiter_match="${BASH_REMATCH[1]}"
        else
          continue
        fi
        HEREDOC_DELIMITER="$delimiter_match"
        return 0
        ;;
    esac
  done
  return 1
}

strip_heredoc_bodies() {
  local text="$1" line="" delimiter="" pending=0 strip_tabs=0 strip_body=1 body_line=""
  # Normalize before parsing so CRLF delimiter lines close their heredoc.
  text="${text//$'\r\n'/$'\n'}"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$pending" -eq 1 ]; then
      body_line="$line"
      if [ "$strip_tabs" -eq 1 ]; then body_line="${body_line#"${body_line%%[!$'\t']*}"}"; fi
      if [ "$body_line" = "$delimiter" ]; then pending=0; delimiter=""; strip_tabs=0
      elif [ "$strip_body" -eq 0 ]; then printf '%s\n' "$line"
      fi
      continue
    fi
    printf '%s\n' "$line"
    if find_heredoc_redirection "$line"; then
      delimiter="$HEREDOC_DELIMITER"
      strip_tabs="$HEREDOC_STRIP_TABS"
      pending=1
      strip_body=1
      heredoc_body_is_executable "$line" && strip_body=0
    fi
  done <<< "$text"
}
flat="$(strip_heredoc_bodies "$command_text")"
flat="${flat//$'\r\n'/$'\n'}"
flat="${flat//$'\n'/ }"

single_hq_monitor_command() {
  local text="$1" stripped="" quote="" escaped=0 char i
  for ((i = 0; i < ${#text}; i++)); do
    char="${text:i:1}"
    if [ "$escaped" -eq 1 ]; then
      [ -z "$quote" ] && stripped+="$char"
      escaped=0
    elif [ -n "$quote" ]; then
      if [ "$quote" != "'" ] && [ "$char" = "\\" ]; then escaped=1
      elif [ "$char" = "$quote" ]; then quote=""; fi
    elif [ "$char" = "\\" ]; then
      escaped=1
    elif [ "$char" = "'" ] || [ "$char" = '"' ] || [ "$char" = $'\140' ]; then
      quote="$char"
    else
      stripped+="$char"
    fi
  done
  [[ "$stripped" =~ ^[[:space:]]*(command[[:space:]]+)?([^[:space:]]*/)?hq[[:space:]]+monitor([[:space:]]|$) ]] || return 1
  [[ "$stripped" != *";"* && "$stripped" != *"&"* && "$stripped" != *"|"* ]]
}

if [ "$runtime" = "claude" ]; then
  [ "$run_background" = "1" ] && exit 0
fi

blocked=0
if [[ "$flat" =~ (^|[;&|[:space:]])sleep[[:space:]]+([0-9]+)([.][0-9]+)?(s|[[:space:]]|$) ]]; then
  seconds="${BASH_REMATCH[2]}"
  while [ "${seconds#0}" != "$seconds" ]; do seconds="${seconds#0}"; done
  case "$seconds" in
    [3-9][0-9]|[0-9][0-9][0-9]*) blocked=1 ;;
  esac
fi
if [[ "$flat" =~ (^|[;&|[:space:]])(while|until)[[:space:]].*sleep[[:space:]]+[0-9]+ ]]; then
  blocked=1
fi
if [[ "$flat" =~ (^|[;&|[:space:]])gh[[:space:]]+run[[:space:]]+watch([[:space:]]|$) ]]; then
  blocked=1
fi
if [[ "$flat" =~ (^|[;&|[:space:]])gh[[:space:]]+pr[[:space:]]+checks([[:space:]].*)?[[:space:]]--watch([[:space:]]|$) ]]; then
  blocked=1
fi
[ "$blocked" -eq 1 ] || exit 0

# Only scan potentially blocked commands for the hq monitor exemption. Quoted
# conditions can contain shell punctuation without turning that invocation
# into a compound command.
single_hq_monitor_command "$flat" && exit 0

root="$(hq_monitor_root)"
[ -n "$root" ] || exit 0
# The advisory SessionStart caller keeps the one-second budget. The blocking
# guard gets a longer bounded probe so an ordinary cold CLI start does not
# disable enforcement for the command being checked. It must stay below this
# hook's registry timeout (5 s) so a stuck CLI ends the probe, not the hook.
if ! hq_monitor_enabled "$root" "$payload" monitor-guard 3; then
  exit 0
fi

blocked_command="${flat:0:117}"
if [ "${#flat}" -le 120 ]; then blocked_command="$flat"; else blocked_command="${blocked_command}..."; fi
case "$runtime" in claude|codex|grok) ;; *) runtime="claude" ;; esac
if [[ "$session_id" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
  target="session:$runtime:$session_id"
else
  target="session:$runtime:<session-id>"
fi
reason="Blocked: $blocked_command. Use hq monitor start --target $target --description '<what>' --command 'until <check>; do sleep 30; done' for this wait. Do not chain shorter sleeps to work around this block."
jq -cn --arg reason "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
