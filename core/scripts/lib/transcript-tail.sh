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
# Return the normal bounded suffix plus the latest complete assistant record
# when later metadata records have pushed it outside that suffix. The fallback
# scan is bounded; status 3 means the latest assistant could not be verified
# within the cap and security-sensitive callers must fail closed.
hq_transcript_tail_with_latest_assistant() {
  [ "$#" -ge 1 ] && [ "$#" -le 3 ] || return 2
  local path="$1" max_bytes="${2:-$HQ_TRANSCRIPT_TAIL_MAX_BYTES}"
  local scan_cap="${3:-16777216}" size normal_tail normal_tail_bytes assistant_record scan_tail
  case "$scan_cap" in ''|*[!0-9]*) return 2 ;; esac
  [ "$scan_cap" -gt 0 ] || return 2

  # Keep the cheap path first: most turns have their newest assistant record in
  # the ordinary bounded suffix, including when older transcript history is
  # larger than the fallback scan cap.
  normal_tail="$(hq_transcript_tail "$path" "$max_bytes")" || return $?
  normal_tail_bytes="$(printf '%s' "$normal_tail" | wc -c | tr -d '[:space:]')"
  if [ "$normal_tail_bytes" -le "$scan_cap" ]; then
    assistant_record="$(printf '%s\n' "$normal_tail" | jq -Rrc 'fromjson? | select(.type == "assistant" or (.type == "response_item" and .payload.type == "message" and .payload.role == "assistant"))' | tail -n 1)"
    if [ -n "$assistant_record" ]; then
      [ -z "$normal_tail" ] || printf '%s\n' "$normal_tail"
      return 0
    fi
  fi

  size="$(hq_transcript_size "$path")" || {
    printf '%s\n' "hq_transcript_tail_with_latest_assistant: cannot read transcript size: $path" >&2
    return 1
  }
  if [ "$size" -le "$scan_cap" ]; then
    scan_tail="$(cat "$path"; printf '.')"
  else
    # Drop the partial first line from this bounded suffix. If the latest
    # assistant record exceeds the cap, it cannot be parsed and the caller
    # fails closed rather than reading an unbounded final line.
    scan_tail="$(tail -c "$((scan_cap + 1))" "$path" | sed '1d'; printf '.')"
  fi
  scan_tail="${scan_tail%.}"
  assistant_record="$(printf '%s\n' "$scan_tail" | jq -Rrc 'fromjson? | select(.type == "assistant" or (.type == "response_item" and .payload.type == "message" and .payload.role == "assistant"))' | tail -n 1)"
  if [ -n "$assistant_record" ]; then
    printf '%s\n' "$assistant_record"
    [ -z "$normal_tail" ] || printf '%s\n' "$normal_tail"
    return 0
  fi

  if [ "$size" -gt "$scan_cap" ] || [ "$normal_tail_bytes" -gt "$scan_cap" ]; then
    printf '%s\n' "hq_transcript_tail_with_latest_assistant: latest assistant record exceeds the ${scan_cap}-byte verification window" >&2
    return 3
  fi

  [ -z "$normal_tail" ] || printf '%s\n' "$normal_tail"
}
