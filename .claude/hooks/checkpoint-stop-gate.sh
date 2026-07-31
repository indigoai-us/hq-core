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
  input_fields="$(printf '%s' "$input" | jq -r '[.transcript_path // "", .session_id // "", .stop_hook_active // ""] | @tsv' 2>/dev/null)" || exit 0
  IFS=$'\t' read -r transcript_path session_id stop_hook_active <<<"$input_fields" || exit 0

  # The sibling maintains HQ after a successful checkpoint. It must never
  # recursively demand another checkpoint of itself.
  [ "${HQ_CHECKPOINT_SIBLING:-}" = "1" ] && exit 0

  # Operator switches precede identity eligibility. A forced gate intentionally
  # bypasses the cached verdict for local trials and regression tests.
  case "${HQ_CHECKPOINT_GATE:-}" in
    0) exit 0 ;;
    1) enforce=true ;;
    *) enforce=false ;;
  esac

  state_dir="$(hq_hook_state_dir "$HQ")"
  [ -d "$state_dir" ] && [ -w "$state_dir" ] || exit 0
  eligibility_file="$state_dir/checkpoint-gate-eligible"

  refresh_eligibility() {
    command -v hq >/dev/null 2>&1 || return 0
    (nohup hq core checkpoint --gate-probe >/dev/null 2>&1 &)
  }

  if [ "$enforce" = false ]; then
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
  block_file="$state_dir/stop-gate-blocks-$session_key"

  # Parse only the recent JSONL tail. Claude tool results are user entries, so
  # a real user turn is a string content entry or an array with a text block.
  # Keeping the raw line lets UUID-less records use the required checksum marker.
  parsed="$(tail -n 400 "$transcript_path" 2>/dev/null | jq -Rrsc '
    def real_user:
      .type == "user" and (
        (.message.content? | type) == "string" or
        ((.message.content? | type) == "array" and any(.message.content[]?; .type == "text"))
      );
    [split("\n")[] | select(length > 0) | {line: ., entry: (fromjson)}] as $rows
    | [range(0; $rows | length) | select($rows[.].entry | real_user)] as $user_indexes
    | if ($user_indexes | length) == 0 then error("no real user entry") else
        $user_indexes[-1] as $user_index
        | [
            $rows[($user_index + 1):][]
            | .entry
            | select(.type == "assistant")
            | .message.content?
            | if type == "array" then .[]? else empty end
            | select(.type == "tool_use")
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
        | [
            ("uuid:" + ($rows[$user_index].entry.uuid? // "")),
            $rows[$user_index].line,
            (if (
              ($tools | length) > 0
              and ($last_tool.name? == "Bash")
              and (($last_tool.input.command? // "") | test("(^|[;&|(\\s])(command\\s+)?([A-Za-z_][A-Za-z0-9_]*=[^\\s]*\\s+)*hq\\s+core\\s+checkpoint(\\s|$)"))
              and ($last_result_error | not)
            ) then "1" else "0" end)
          ] | @tsv
      end
  ' 2>/dev/null)" || exit 0
  [ -n "$parsed" ] || exit 0

  IFS=$'\t' read -r marker_field marker_line satisfied <<<"$parsed" || exit 0
  case "$marker_field" in
    uuid:*) turn_marker="${marker_field#uuid:}" ;;
    *) exit 0 ;;
  esac
  if [ -z "$turn_marker" ]; then
    [ -n "$marker_line" ] || exit 0
    marker_hash="$(printf '%s' "$marker_line" | cksum 2>/dev/null | awk '{print $1 "-" $2}')"
    [ -n "$marker_hash" ] || exit 0
    turn_marker="line-$marker_hash"
  fi

  # The state records repeated blocks of this exact turn. stop_hook_active
  # counts as one prior block only when there is no persisted state yet.
  prior_marker=""
  prior_count=0
  state_present=false
  if [ -e "$block_file" ]; then
    [ -r "$block_file" ] || exit 0
    IFS=' ' read -r prior_marker prior_count <"$block_file" || exit 0
    case "$prior_count" in
      ''|*[!0-9]*) exit 0 ;;
    esac
    state_present=true
  fi

  current_count=0
  if [ "$state_present" = true ] && [ "$prior_marker" = "$turn_marker" ]; then
    current_count="$prior_count"
  elif [ "$state_present" = false ] && [ "$stop_hook_active" = "true" ]; then
    current_count=1
  fi
  [ "$current_count" -ge 2 ] && exit 0

  if [ "$satisfied" = "1" ]; then
    rm -f "$block_file" 2>/dev/null || true
    exit 0
  fi

  reason_prefix='End-of-turn checkpoint required. As the FINAL action of this turn run: hq core checkpoint --session-id '
  reason_suffix=' --trigger stop-gate --summary "<one-line outcome>" [--learning "..."] [--decision "..."] [--next "..."] [--file <path>] — or `hq core checkpoint --session-id '
  reason_suffix_2=' --idle` if the turn changed nothing. Then end the turn immediately after the command.'
  reason="${reason_prefix}${session_id}${reason_suffix}${session_id}${reason_suffix_2}"
  printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$reason" | hq_json_encode)"
  printf '%s %s\n' "$turn_marker" "$((current_count + 1))" >"$block_file" 2>/dev/null || true
} 2>/dev/null || true

exit 0
