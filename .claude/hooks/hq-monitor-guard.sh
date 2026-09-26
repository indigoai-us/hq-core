#!/bin/bash
# Gated foreground-wait guard for Claude, Codex, and Grok shell calls.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/hq-monitor-hook-lib.sh"

payload="$(</dev/stdin)" || payload='{}'
[ "${HQ_LANE_ID+x}" = x ] && exit 0

runtime="${HQ_CHECKPOINT_RUNTIME:-claude}"
command_text="$(printf '%s' "$payload" | jq -r '.tool_input.command // .toolInput.command // empty' 2>/dev/null || true)"
[ -n "$command_text" ] || exit 0
flat="${command_text//$'\n'/ }"

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
  run_background="$(printf '%s' "$payload" | jq -r '.tool_input.run_in_background // .toolInput.run_in_background // false' 2>/dev/null || true)"
  [ "$run_background" = "true" ] && exit 0
fi

blocked=0
if [[ "$flat" =~ (^|[;&|[:space:]])sleep[[:space:]]+([0-9]+([.][0-9]+)?)(s|[[:space:]]|$) ]]; then
  seconds="${BASH_REMATCH[2]}"
  awk -v seconds="$seconds" 'BEGIN { exit !(seconds + 0 >= 30) }' && blocked=1
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
if ! hq_monitor_enabled "$root" "$payload"; then
  exit 0
fi

blocked_command="${flat:0:117}"
if [ "${#flat}" -le 120 ]; then blocked_command="$flat"; else blocked_command="${blocked_command}..."; fi
reason="Blocked: $blocked_command. Use hq monitor start --description '<what>' --command 'until <check>; do sleep 30; done' for this wait. Do not chain shorter sleeps to work around this block."
jq -cn --arg reason "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
