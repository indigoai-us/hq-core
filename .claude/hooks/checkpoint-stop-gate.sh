#!/usr/bin/env bash
# Stop hook: require hq core checkpoint as an eligible operator's final tool
# call. Every error path is deliberately fail-open: a broken gate must never
# strand a Claude session.

set -uo pipefail

{
  self_hq="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
  HQ="${CLAUDE_PROJECT_DIR:-${HQ_ROOT:-$self_hq}}"
  HQ="${HQ:-${HOME}/Documents/HQ}"
  [ -n "$self_hq" ] || exit 0
  . "$self_hq/core/scripts/hook-lib.sh"

  input="$(cat 2>/dev/null || printf '{}')"
  input_fields="$(printf '%s' "$input" | jq -r '[.transcript_path // "", .session_id // ""] | @tsv' 2>/dev/null)" || exit 0
  IFS=$'\t' read -r transcript_path session_id <<<"$input_fields" || exit 0

  # The sibling maintains HQ after a successful checkpoint. It must never
  # recursively demand another checkpoint of itself.
  [ "${HQ_CHECKPOINT_SIBLING:-}" = "1" ] && exit 0

  runtime="${HQ_CHECKPOINT_RUNTIME:-claude}"

  # Operator switches precede runtime and identity eligibility. A forced gate
  # intentionally bypasses the rollout rules for local trials and tests.
  case "${HQ_CHECKPOINT_GATE:-}" in
    0) exit 0 ;;
    1) enforce=true ;;
    *)
      case "$runtime" in
        claude) enforce=true ;;
        codex) enforce=false ;;
        *) exit 0 ;;
      esac
      ;;
  esac

  state_dir="$(hq_hook_state_dir "$HQ")"
  [ -d "$state_dir" ] && [ -w "$state_dir" ] || exit 0
  eligibility_file="$state_dir/checkpoint-gate-eligible-$runtime"

  refresh_eligibility() {
    command -v hq >/dev/null 2>&1 || return 0
    (nohup env HQ_CHECKPOINT_RUNTIME="$runtime" hq core checkpoint --gate-probe >/dev/null 2>&1 &)
  }

  if [ "$runtime" = "codex" ] && [ "$enforce" = false ]; then
    if [ ! -e "$eligibility_file" ]; then
      refresh_eligibility
      exit 0
    fi
    [ -r "$eligibility_file" ] || exit 0
    eligibility="$(tr -d '\r\n' <"$eligibility_file" 2>/dev/null || true)"
    case "$eligibility" in
      0) exit 0 ;;
      1)
        # GNU `stat -f` succeeds but prints filesystem metadata, so try its
        # file-mtime form first; macOS then falls back to `stat -f %m`.
        eligibility_mtime="$(stat -c %Y "$eligibility_file" 2>/dev/null || stat -f %m "$eligibility_file" 2>/dev/null || true)"
        case "$eligibility_mtime" in
          ''|*[!0-9]*) exit 0 ;;
        esac
        now="$(date +%s 2>/dev/null || true)"
        case "$now" in
          ''|*[!0-9]*) exit 0 ;;
        esac
        if [ $((now - eligibility_mtime)) -gt 86400 ]; then
          refresh_eligibility
        fi
        enforce=true
        ;;
      *) exit 0 ;;
    esac
  fi

  # Do not infer a tool or session when Claude has not supplied the fields.
  command -v hq >/dev/null 2>&1 || exit 0
  [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && [ -r "$transcript_path" ] || exit 0
  [ -n "$session_id" ] || exit 0

  session_key="$(hq_hook_safe_session_key "$session_id")"
  [ -n "$session_key" ] || exit 0

  # Parse only the recent JSONL tail. Claude and Codex persist different row
  # shapes, so normalize both to the same user/tool boundary before checking
  # whether the final action was the checkpoint command.
  parsed="$(tail -n 400 "$transcript_path" 2>/dev/null | jq -Rrsc '
    def claude_user:
      .type == "user" and (
        (.message.content? | type) == "string" or
        ((.message.content? | type) == "array" and any(.message.content[]?; .type == "text"))
      );
    def codex_user:
      .type == "response_item"
      and .payload.type? == "message"
      and .payload.role? == "user"
      and ((.payload.content? | type) == "array")
      and any(.payload.content[]?; .type == "input_text");
    def real_user: claude_user or codex_user;
    def javascript_object_cmd:
      capture("(^|[,{}])\\s*cmd\\s*:\\s*(?<quoted>\"(?:\\\\.|[^\"\\\\])*\")")
      | .quoted
      | fromjson;
    def codex_command:
      if .name? == "exec" and ((.input? | type) == "string") then
        try (
          .input
          | capture("tools\\.exec_command\\((?<args>\\{.*\\})\\);")
          | .args
          | try (fromjson | .cmd // "") catch javascript_object_cmd
        ) catch ""
      elif (.name? == "exec_command" or .name? == "Bash") then
        if ((.input? | type) == "object") then
          .input.cmd? // .input.command? // ""
        elif ((.input? | type) == "string") then
          try (.input | fromjson | .cmd? // .command? // "") catch .input
        elif ((.arguments? | type) == "string") then
          try (.arguments | fromjson | .cmd? // .command? // "") catch ""
        else ""
        end
      else ""
      end;
    def checkpoint_command:
      test("(^|[;&|(\\s])(command\\s+)?([A-Za-z_][A-Za-z0-9_]*=[^\\s]*\\s+)*hq\\s+core\\s+checkpoint(\\s|$)");
    [split("\n")[] | select(length > 0) | {line: ., entry: (fromjson)}] as $rows
    | [range(0; $rows | length) | select($rows[.].entry | real_user)] as $user_indexes
    | if ($user_indexes | length) == 0 then error("no real user entry") else
        $user_indexes[-1] as $user_index
        | [
            $rows[($user_index + 1):][]
            | .entry
            | if .type == "assistant" then
                .message.content?
                | if type == "array" then .[]? else empty end
                | select(.type == "tool_use")
                | {
                    runtime: "claude",
                    id: (.id? // ""),
                    name: (.name? // ""),
                    command: (.input.command? // "")
                  }
              elif (
                .type == "response_item"
                and (.payload.type? == "custom_tool_call" or .payload.type? == "function_call")
              ) then
                .payload
                | {
                    runtime: "codex",
                    id: (.call_id? // .id? // ""),
                    name: (.name? // ""),
                    command: codex_command
                  }
              else empty
              end
          ] as $tools
        | (if ($tools | length) > 0 then $tools[-1] else {} end) as $last_tool
        | ([
             $rows[]
             | .entry
             | select(.type == "user")
             | .message.content?
             | if type == "array" then .[]? else empty end
             | select(.type == "tool_result" and (.tool_use_id? == $last_tool.id?))
             | (.is_error? // false)
          ] | any(. == true)) as $last_result_error
        | if (
            ($tools | length) > 0
            and ($last_tool.command | checkpoint_command)
          ) then
            if $last_tool.runtime == "claude" and ($last_result_error | not) then "1"
            elif $last_tool.runtime == "codex" then "stamp"
            else "0"
            end
          else "0"
          end
      end
  ' 2>/dev/null)" || exit 0
  satisfied="$parsed"
  case "$satisfied" in
    0|1|stamp) ;;
    *) exit 0 ;;
  esac

  # Codex tool-result envelopes do not reliably expose a nested shell exit
  # status. The CLI writes this session-scoped stamp only after a successful
  # checkpoint, so require a fresh stamp in addition to the final command.
  if [ "$satisfied" = "stamp" ]; then
    satisfied=0
    stamp_file="$state_dir/checkpoint-cli-last-$session_key"
    if [ -r "$stamp_file" ]; then
      stamp_epoch="$(tr -d '\r\n' <"$stamp_file" 2>/dev/null || true)"
      now="$(date +%s 2>/dev/null || true)"
      case "$stamp_epoch:$now" in
        *[!0-9:]*|:*) ;;
        *)
          stamp_age=$((now - stamp_epoch))
          if [ "$stamp_age" -ge 0 ] && [ "$stamp_age" -le 120 ]; then
            satisfied=1
          fi
          ;;
      esac
    fi
  fi

  if [ "$satisfied" = "1" ]; then
    if [ "$runtime" = "codex" ]; then
      rm -f "$state_dir/codex-checkpoint-reprompt-$session_key" 2>/dev/null || true
    fi
    exit 0
  fi

  reason_prefix='End-of-turn checkpoint required. As the FINAL action of this turn run: hq core checkpoint --session-id '
  reason_suffix=' --trigger stop-gate --summary "<one-line outcome>" [--learning "..."] [--decision "..."] [--next "..."] [--file <path>] — or `hq core checkpoint --session-id '
  reason_suffix_2=' --idle` if the turn changed nothing. Then end the turn immediately after the command.'
  reason="${reason_prefix}${session_id}${reason_suffix}${session_id}${reason_suffix_2}"

  # Codex surfaces a blocked Stop reason as a synthetic user prompt. Preserve
  # the actionable instruction out-of-band, then use the stable marker covered
  # by the guidance preloaded at SessionStart.
  if [ "$runtime" = "codex" ]; then
    reprompt_file="$state_dir/codex-checkpoint-reprompt-$session_key"
    reprompt_tmp="$reprompt_file.$$"
    if (umask 077 && printf '%s' "$reason" >"$reprompt_tmp" && mv -f "$reprompt_tmp" "$reprompt_file"); then
      reason='Hook re-prompted Codex'
    else
      rm -f "$reprompt_tmp" 2>/dev/null || true
    fi
  fi
  printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$reason" | hq_json_encode)"
} 2>/dev/null || true

exit 0
