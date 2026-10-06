#!/usr/bin/env bash
# Shared bounded reads for JSONL transcripts on hot hook paths.

HQ_TRANSCRIPT_TAIL_MAX_BYTES=1048576

# hq_transcript_size <path>
# Report the file's exact byte size from filesystem metadata without reading
# its contents.
hq_transcript_size() {
  [ "$#" -eq 1 ] || return 2
  local path="$1" size=""
  size="$(stat -L -c %s "$path" 2>/dev/null || true)"
  case "$size" in
    ''|*[!0-9]*)
      size="$(stat -L -f %z "$path" 2>/dev/null || true)"
      ;;
  esac
  case "$size" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$size"
}

# hq_transcript_tail <path> [max_bytes]
# Keep a complete-line suffix of a JSONL transcript. The extra byte is a
# boundary sentinel: when the tail starts mid-record, sed drops that partial
# first line. If the byte window contains no complete line because the newest
# record is oversized, return only that final record.
hq_transcript_tail() {
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || return 2
  local path="$1" max_bytes="${2:-$HQ_TRANSCRIPT_TAIL_MAX_BYTES}" size
  case "$max_bytes" in
    ''|*[!0-9]*) return 2 ;;
  esac
  [ "$max_bytes" -gt 0 ] || return 2
  size="$(hq_transcript_size "$path")" || {
    printf '%s\n' "hq_transcript_tail: cannot read transcript size: $path" >&2
    return 1
  }
  if [ "$size" -le "$((max_bytes + 1))" ]; then
    cat "$path"
    return $?
  fi
  local bounded_tail
  bounded_tail="$(tail -c "$((max_bytes + 1))" "$path" | sed '1d'; printf '.')"
  bounded_tail="${bounded_tail%.}"
  if [ -n "$bounded_tail" ]; then
    printf '%s' "$bounded_tail"
  else
    # The newest record itself may be larger than the byte window. Keep that
    # complete record so safety and capture hooks can still inspect it.
    tail -n 1 "$path"
  fi
}

# hq_transcript_tail_with_latest_assistant <path> [max_bytes] [scan_cap_bytes]
# Return the normal bounded suffix plus the newest complete assistant record
# when later records pushed it outside that suffix. The third argument remains
# accepted for caller compatibility, but reverse scanning is no longer capped.
# Return 1 only when the transcript cannot be read or no reverse-line tool is
# available; callers handling user-facing policy checks must fail open silently.
hq_transcript_tail_with_latest_assistant() {
  [ "$#" -ge 1 ] && [ "$#" -le 3 ] || return 2
  local path="$1" max_bytes="${2:-$HQ_TRANSCRIPT_TAIL_MAX_BYTES}"
  local scan_cap="${3:-16777216}" normal_tail assistant_record reverse_mode line=""
  case "$scan_cap" in ''|*[!0-9]*) return 2 ;; esac
  [ "$scan_cap" -gt 0 ] || return 2

  # Most turns keep their newest assistant record in the ordinary bounded
  # suffix, so preserve that fast path before any reverse scan.
  normal_tail="$(hq_transcript_tail "$path" "$max_bytes")" || return $?
  assistant_record="$(printf '%s\n' "$normal_tail" | jq -Rrc 'fromjson? | select(.type == "assistant" or (.type == "response_item" and .payload.type == "message" and .payload.role == "assistant"))' | tail -n 1)"
  if [ -n "$assistant_record" ]; then
    [ -z "$normal_tail" ] || printf '%s\n' "$normal_tail"
    return 0
  fi

  # GNU tac and BSD/macOS tail -r both stream records from EOF toward the
  # beginning. grep discards ordinary tool-output lines before Bash reads them;
  # jq confirms candidates and the loop exits at the newest assistant.
  if command -v tac >/dev/null 2>&1; then
    reverse_mode=tac
  elif tail -r /dev/null >/dev/null 2>&1; then
    reverse_mode=tail-r
  else
    printf '%s\n' "hq_transcript_tail_with_latest_assistant: no reverse-line reader is available" >&2
    return 1
  fi

  assistant_record="$(
    if [ "$reverse_mode" = tac ]; then
      { tac "$path" 2>/dev/null || true; }
    else
      { tail -r "$path" 2>/dev/null || true; }
    fi | { grep -E '"assistant"' || true; } | while IFS= read -r line || [ -n "$line" ]; do
      # grep filters large non-assistant records before Bash reads their lines.
      if printf '%s\n' "$line" | jq -Rre 'fromjson? | select(.type == "assistant" or (.type == "response_item" and .payload.type == "message" and .payload.role == "assistant"))' >/dev/null 2>&1; then
        printf '%s\n' "$line"
        break
      fi
    done
  )"
  if [ -n "$assistant_record" ]; then
    printf '%s\n' "$assistant_record"
  fi
  [ -z "$normal_tail" ] || printf '%s\n' "$normal_tail"
  return 0
}
