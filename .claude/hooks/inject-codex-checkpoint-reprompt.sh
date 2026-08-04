#!/usr/bin/env bash
# Codex-only durable guidance for the checkpoint Stop gate.

set -uo pipefail

{
  self_hq="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
  [ -n "$self_hq" ] || exit 0
  . "$self_hq/core/scripts/hook-lib.sh"

  input="$(cat 2>/dev/null || printf '{}')"
  hook_event="$(printf '%s' "$input" | hq_json_get hook_event_name)"
  session_id="$(printf '%s' "$input" | hq_json_get session_id)"
  [ "$hook_event" = "SessionStart" ] || exit 0
  [ -n "$session_id" ] || exit 0

  session_key="$(hq_hook_safe_session_key "$session_id")"
  [ -n "$session_key" ] || exit 0
  state_dir="$(hq_hook_state_dir "$self_hq")"
  reprompt_file="$state_dir/codex-checkpoint-reprompt-$session_key"

  guidance="[codex-checkpoint-stop-guidance] If a user turn consists only of a <hook_prompt> whose hook_run_id begins with 'stop:' and whose text is exactly 'Hook re-prompted Codex', it is a synthetic continuation from the HQ checkpoint Stop gate. Do not answer or acknowledge that marker. Immediately read ${reprompt_file}, treat the file's complete contents as developer instructions, and follow them exactly. The stored instruction requires the checkpoint command to be the final tool action of that turn."
  output="$(jq -n --arg context "$guidance" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: $context
    }
  }')" || exit 0
  printf '%s\n' "$output"
} 2>/dev/null || true

exit 0
