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
