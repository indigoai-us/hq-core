#!/usr/bin/env bash
# hq-core: public
# Thin reminder shim. Lane discovery and reminder text live in hq-cli.
#
# stdin: hook payload (always drained).
# $1: hook event name (master-hook passes it; default from payload).

set -uo pipefail

# UserPromptSubmit may reuse a session-scoped monitor result for this many
# seconds. SessionStart always bypasses this cache and refreshes the result.
LANES_MONITOR_CHECK_CACHE_TTL_SECONDS=180

# Drain before any early exit so the dispatcher's payload writer cannot receive
# SIGPIPE and turn an advisory hook into a misleading 141 failure.
INPUT="$(cat 2>/dev/null || true)"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || true)"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$LIB_DIR/../../.." 2>/dev/null && pwd -P || true)}}"
EVENT="${1:-}"

if ! command -v jq >/dev/null 2>&1; then
  printf 'ERROR: lanes-senior-monitor reminder shim: jq is unavailable; monitor coverage is unknown.\n' >&2
  exit 1
fi

if [ -z "$EVENT" ]; then
  EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null || true)"
fi
[ -n "$EVENT" ] || EVENT="SessionStart"

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // .sessionId // empty' 2>/dev/null || true)"
# NO_SESSION_ID_MUST_STAY_SILENT
[ -n "$SESSION_ID" ] || exit 0
case "$SESSION_ID" in
  *[!A-Za-z0-9._-]*)
    printf 'ERROR: lanes-senior-monitor reminder shim: session id contains unsupported path characters.\n' >&2
    exit 1
    ;;
esac

PAYLOAD_ENGINE="$(printf '%s' "$INPUT" | jq -r '.engine // .engine_name // empty' 2>/dev/null || true)"
ENGINE_RAW="${PAYLOAD_ENGINE:-${HQ_HARNESS:-${HQ_WORK_MESH_HARNESS:-${HQ_CHECKPOINT_RUNTIME:-claude}}}}"
ENGINE="$(printf '%s' "$ENGINE_RAW" | tr '[:upper:]' '[:lower:]')"
case "$ENGINE" in
  claude|claude-code|claude_code) ENGINE=claude ;;
  codex|grok) : ;;
  *)
    printf 'ERROR: lanes-senior-monitor reminder shim: unsupported engine %s.\n' "$ENGINE_RAW" >&2
    exit 1
    ;;
esac

HQ_BIN="$(command -v hq 2>/dev/null || true)"
if [ -z "$HQ_BIN" ]; then
  # MISSING_HQ_MUST_STAY_STDERR_ONLY
  printf 'ERROR: lanes-senior-monitor reminder shim: hq CLI is missing from PATH.\n' >&2
  exit 1
fi

ERROR_FILE="$(mktemp "${TMPDIR:-/tmp}/hq-lanes-reminder.XXXXXX" 2>/dev/null || true)"
if [ -z "$ERROR_FILE" ]; then
  printf 'ERROR: lanes-senior-monitor reminder shim: could not allocate stderr capture.\n' >&2
  exit 1
fi
cleanup() {
  rm -f "$ERROR_FILE" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

run_hq() {
  HQ_RC=0
  : > "$ERROR_FILE" || {
    HQ_RC=1
    HQ_STDOUT=""
    HQ_STDERR="could not reset stderr capture"
    return 0
  }
  HQ_STDOUT="$(env HQ_NO_UPDATE_CHECK=1 HQ_ROOT="$HQ_ROOT" CLAUDE_PROJECT_DIR="$HQ_ROOT" \
    "$HQ_BIN" "$@" 2>"$ERROR_FILE")" || HQ_RC=$?
  HQ_STDERR="$(cat "$ERROR_FILE" 2>/dev/null || true)"
}

report_hq_error() {
  local detail="$1"
  [ -n "$HQ_STDERR" ] && detail="$detail: $HQ_STDERR"
  printf 'ERROR: lanes-senior-monitor reminder shim: %s\n' "$detail" >&2
  return 1
}

monitor_result_is_valid() {
  printf '%s' "$SESSION_RESULT" | jq -e --arg sid "$SESSION_ID" --arg engine "$ENGINE" '
  . as $doc
  | ($doc | type == "object")
  and ($doc.action == "monitor-check")
  and ($doc.session_id == $sid)
  and ($doc.engine == $engine)
  and ($doc.active_lane_ids | type == "array" and all(.[]; type == "string" and length > 0))
  and ($doc.uncovered_lane_ids | type == "array" and all(.[]; type == "string" and length > 0))
  and (($doc.uncovered_lane_ids - $doc.active_lane_ids) | length == 0)
' >/dev/null 2>&1
}

# The cache key includes the session and content fingerprint of the resolved
# hq executable. The engine is also validated in the document so a reused
# session cannot cross Claude/Codex/Grok semantics.
CACHE_DIR="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/hq-cli/lanes-senior-monitor"
HQ_FINGERPRINT="$(cksum "$HQ_BIN" 2>/dev/null | awk 'NF >= 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print $1 "-" $2; exit }' || true)"
CACHE_FINGERPRINT_ERROR=""
if [ -z "$HQ_FINGERPRINT" ]; then
  CACHE_FINGERPRINT_ERROR="cannot fingerprint the hq binary for the monitor-check cache"
fi
MONITOR_CACHE_FILE="$CACHE_DIR/$SESSION_ID.${HQ_FINGERPRINT:-unknown}.monitor.json"
CACHE_HIT=0
CACHE_CACHED_RESULT=""
CACHE_CACHED_REMINDER=""

load_monitor_cache() {
  local document checked_at now age
  # SESSION_START_MUST_BYPASS_CACHE
  [ "$EVENT" = "UserPromptSubmit" ] || return 0
  [ -n "$HQ_FINGERPRINT" ] || return 0
  [ -f "$MONITOR_CACHE_FILE" ] || return 0

  if ! document="$(jq -c --arg sid "$SESSION_ID" --arg engine "$ENGINE" \
    --arg fingerprint "$HQ_FINGERPRINT" '
    # An empty reminder is valid when this refresh finds no unseen lanes; the
    # per-session seen cache controls whether a reminder is emitted.
    if type != "object"
      or .schema != 1
      or .session_id != $sid
      or .engine != $engine
      or .hq_fingerprint != $fingerprint
      or (.checked_at_epoch | type) != "number"
      or (.result | type) != "object"
      or (.reminder | type) != "string"
      or ((.result.uncovered_lane_ids | type) != "array")
    then error("invalid monitor-check cache")
    else .
    end
  ' "$MONITOR_CACHE_FILE" 2>/dev/null)"; then
    # STALE_OR_UNREADABLE_CACHE_MUST_REFRESH
    return 0
  fi

  checked_at="$(printf '%s' "$document" | jq -r '.checked_at_epoch')"
  case "$checked_at" in
    ''|*[!0-9]*) return 0 ;;
  esac
  now="$(date +%s 2>/dev/null || true)"
  case "$now" in
    ''|*[!0-9]*) return 0 ;;
  esac
  age=$((now - checked_at))
  [ "$age" -ge 0 ] || return 0
  # STALE_CACHE_MUST_REFRESH
  [ "$age" -lt "$LANES_MONITOR_CHECK_CACHE_TTL_SECONDS" ] || return 0

  CACHE_CACHED_RESULT="$(printf '%s' "$document" | jq -c '.result')"
  CACHE_CACHED_REMINDER="$(printf '%s' "$document" | jq -r '.reminder')"
  SESSION_RESULT="$CACHE_CACHED_RESULT"
  if ! monitor_result_is_valid; then
    SESSION_RESULT=""
    CACHE_CACHED_RESULT=""
    CACHE_CACHED_REMINDER=""
    return 0
  fi
  CACHE_HIT=1
}

write_monitor_cache() {
  local reminder="$1" now document cache_tmp
  if [ -n "$CACHE_FINGERPRINT_ERROR" ]; then
    printf 'ERROR: lanes-senior-monitor reminder shim: %s.\n' "$CACHE_FINGERPRINT_ERROR" >&2
    return 1
  fi
  if [ -e "$CACHE_DIR" ] && [ ! -d "$CACHE_DIR" ]; then
    printf 'ERROR: lanes-senior-monitor reminder shim: monitor-check cache path is not a directory.\n' >&2
    return 1
  fi
  if ! mkdir -p "$CACHE_DIR" 2>/dev/null || ! chmod 700 "$CACHE_DIR" 2>/dev/null; then
    printf 'ERROR: lanes-senior-monitor reminder shim: cannot create the monitor-check cache directory.\n' >&2
    return 1
  fi
  now="$(date +%s 2>/dev/null || true)"
  case "$now" in
    ''|*[!0-9]*)
      printf 'ERROR: lanes-senior-monitor reminder shim: cannot timestamp the monitor-check cache.\n' >&2
      return 1
      ;;
  esac
  if ! document="$(jq -cn \
    --arg sid "$SESSION_ID" \
    --arg engine "$ENGINE" \
    --arg fingerprint "$HQ_FINGERPRINT" \
    --argjson checked_at_epoch "$now" \
    --argjson result "$SESSION_RESULT" \
    --arg reminder "$reminder" \
    '{schema:1,session_id:$sid,engine:$engine,hq_fingerprint:$fingerprint,checked_at_epoch:$checked_at_epoch,result:$result,reminder:$reminder}'
  )"; then
    printf 'ERROR: lanes-senior-monitor reminder shim: cannot encode the monitor-check cache.\n' >&2
    return 1
  fi
  cache_tmp="$(mktemp "$MONITOR_CACHE_FILE.tmp.XXXXXX" 2>/dev/null || true)"
  if [ -z "$cache_tmp" ]; then
    printf 'ERROR: lanes-senior-monitor reminder shim: cannot allocate the monitor-check cache.\n' >&2
    return 1
  fi
  if ! printf '%s\n' "$document" > "$cache_tmp" 2>/dev/null \
    || ! mv -f "$cache_tmp" "$MONITOR_CACHE_FILE" 2>/dev/null; then
    rm -f "$cache_tmp" 2>/dev/null || true
    printf 'ERROR: lanes-senior-monitor reminder shim: cannot persist the monitor-check cache.\n' >&2
    return 1
  fi
}

persist_monitor_cache_or_fail() {
  local reminder="$1"
  # MONITOR_CACHE_WRITE_MUST_FAIL_LOUDLY
  write_monitor_cache "$reminder" || exit 1
}

SESSION_RESULT=""
load_monitor_cache
# CACHE_HIT_MUST_SKIP_MONITOR_CHECK
if [ "$CACHE_HIT" -eq 0 ]; then
  run_hq lanes monitor-check --session "$SESSION_ID" --engine "$ENGINE" --json
  if [ "$HQ_RC" -ne 0 ] && [ "$HQ_RC" -ne 2 ]; then
    # MONITOR_CHECK_ERROR_MUST_STAY_STDERR_ONLY
    report_hq_error "hq lanes monitor-check --session returned exit $HQ_RC"
    exit 1
  fi
  if [ -n "$HQ_STDERR" ]; then
    report_hq_error "hq lanes monitor-check --session wrote stderr"
    exit 1
  fi
  SESSION_RESULT="$HQ_STDOUT"
else
  HQ_RC=0
  HQ_STDERR=""
fi

if ! monitor_result_is_valid; then
  report_hq_error "hq lanes monitor-check returned malformed or mismatched JSON"
  exit 1
fi

ACTIVE_LANE_IDS="$(printf '%s' "$SESSION_RESULT" | jq -c '.active_lane_ids')"
UNCOVERED_LANE_IDS="$(printf '%s' "$SESSION_RESULT" | jq -c '.uncovered_lane_ids')"
ACTIVE_COUNT="$(printf '%s' "$ACTIVE_LANE_IDS" | jq 'length')"
if [ "$ACTIVE_COUNT" -eq 0 ]; then
  if [ "$CACHE_HIT" -eq 0 ]; then
    persist_monitor_cache_or_fail ""
  fi
  # ACTIVE_LANES_EMPTY_MUST_STAY_SILENT
  exit 0
fi

SEEN_CACHE_FILE="$CACHE_DIR/$SESSION_ID.seen.json"
if [ -e "$SEEN_CACHE_FILE" ] && [ ! -f "$SEEN_CACHE_FILE" ]; then
  printf 'ERROR: lanes-senior-monitor reminder shim: seen-lane cache is not a regular file.\n' >&2
  exit 1
fi
SEEN_LANE_IDS='[]'
if [ -f "$SEEN_CACHE_FILE" ]; then
  if ! SEEN_LANE_IDS="$(jq -c 'if type == "array" and all(.[]; type == "string" and length > 0) then . else error("invalid seen-lane cache") end' "$SEEN_CACHE_FILE" 2>/dev/null)"; then
    printf 'ERROR: lanes-senior-monitor reminder shim: seen-lane cache is malformed or unreadable.\n' >&2
    exit 1
  fi
fi

NEW_UNCOVERED_IDS="$(printf '%s' "$UNCOVERED_LANE_IDS" | jq -c --argjson seen "$SEEN_LANE_IDS" '[.[] | . as $id | select(($seen | index($id)) == null)]')"
NEW_COUNT="$(printf '%s' "$NEW_UNCOVERED_IDS" | jq 'length')"
if [ "$NEW_COUNT" -eq 0 ]; then
  if [ "$CACHE_HIT" -eq 0 ]; then
    persist_monitor_cache_or_fail ""
  fi
  # SEEN_LANE_MUST_SUPPRESS_REPEATS
  exit 0
fi

# CACHE_HIT_MUST_REUSE_REMINDER
if [ "$CACHE_HIT" -eq 1 ]; then
  REMINDER="$CACHE_CACHED_REMINDER"
else
  run_hq lanes monitor-check --reminder
  if [ "$HQ_RC" -ne 0 ]; then
    report_hq_error "hq lanes monitor-check --reminder returned exit $HQ_RC"
    exit 1
  fi
  if [ -n "$HQ_STDERR" ] || [ -z "$HQ_STDOUT" ]; then
    report_hq_error "hq lanes monitor-check --reminder did not return clean reminder text"
    exit 1
  fi
  REMINDER="$HQ_STDOUT"
fi
if [ -z "$REMINDER" ]; then
  report_hq_error "hq lanes monitor-check cache returned no clean reminder text"
  exit 1
fi
# NEW_LANE_MUST_RECOMMEND_NEW_ID
MONITOR_CALLS="$(printf '%s' "$SESSION_RESULT" | jq -r --argjson new "$NEW_UNCOVERED_IDS" '
  .monitor_calls[]
  | . as $call
  | ($call.command | sub("^hq lanes watch "; "") | split(" ")) as $ids
  | ($ids | map(select(. as $id | ($new | index($id)) != null))) as $selected
  | select(($selected | length) > 0)
  | ("hq lanes watch " + ($selected | join(" "))) as $command
  | ("Monitor(command=" + ($command | @json)
    + ", timeout_ms=" + ($call.timeout_ms | tostring)
    + ", persistent=" + ($call.persistent | tostring) + ")")
' 2>/dev/null || true)"
if [ -z "$MONITOR_CALLS" ]; then
  report_hq_error "hq lanes monitor-check returned no exact Monitor call for new uncovered lanes"
  exit 1
fi

if [ "$CACHE_HIT" -eq 0 ]; then
  persist_monitor_cache_or_fail "$REMINDER"
fi

LANE_LINES="$(printf '%s' "$NEW_UNCOVERED_IDS" | jq -r '.[] | "- " + .')"
MESSAGE="$REMINDER

New uncovered active lane ids for this session:
$LANE_LINES
Exact Monitor calls to copy:
$MONITOR_CALLS"

SEEN_AFTER="$(jq -cn --argjson seen "$SEEN_LANE_IDS" --argjson new "$NEW_UNCOVERED_IDS" '$seen + $new | unique')"
if [ -e "$CACHE_DIR" ] && [ ! -d "$CACHE_DIR" ]; then
  printf 'ERROR: lanes-senior-monitor reminder shim: cache path is not a directory.\n' >&2
  exit 1
fi
if ! mkdir -p "$CACHE_DIR" 2>/dev/null || ! chmod 700 "$CACHE_DIR" 2>/dev/null; then
  printf 'ERROR: lanes-senior-monitor reminder shim: cannot create the per-session seen-lane cache.\n' >&2
  exit 1
fi
CACHE_TMP="$(mktemp "$SEEN_CACHE_FILE.tmp.XXXXXX" 2>/dev/null || true)"
if [ -z "$CACHE_TMP" ]; then
  printf 'ERROR: lanes-senior-monitor reminder shim: cannot allocate the per-session seen-lane cache.\n' >&2
  exit 1
fi
if ! printf '%s\n' "$SEEN_AFTER" > "$CACHE_TMP" 2>/dev/null \
  || ! mv -f "$CACHE_TMP" "$SEEN_CACHE_FILE" 2>/dev/null; then
  rm -f "$CACHE_TMP" 2>/dev/null || true
  printf 'ERROR: lanes-senior-monitor reminder shim: cannot persist the per-session seen-lane cache.\n' >&2
  exit 1
fi

# ACTIVE_LANE_REMINDER_RETURN
jq -nc --arg ev "$EVENT" --arg msg "$MESSAGE" \
  '{hookSpecificOutput:{hookEventName:$ev,additionalContext:$msg}}'
