#!/usr/bin/env bash
# hq-core: public
# Instruct a session that is the senior of a still-askable lane to arm a
# 20-minute Monitor on that lane's response.
#
# A shell hook cannot start a Monitor (Monitor is an agent-side tool). This
# script only detects the condition and injects additionalContext telling the
# session to arm the watch. The Monitor is session-scoped and dies with the
# session; that mortality is stated in the injected text.
#
# Silent (exit 0, empty stdout, empty stderr) when this session is senior of
# nothing askable. An unreadable or malformed store is an error on stderr,
# never a silent "no lanes".
#
# stdin: hook payload (always drained).
# $1: hook event name (master-hook passes it; default from payload).

set -euo pipefail

# Always drain stdin first so a dispatcher writing the payload cannot die of
# SIGPIPE on an early exit (hooks-drain-stdin-before-early-exit).
INPUT="$(cat 2>/dev/null || true)"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Data tree (lanes store, session state) is the live HQ root. Implementation
# lives next to hq-session.sh; a mutated copy in /tmp falls back to HQ_ROOT.
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$LIB_DIR/../../.." && pwd)}}"
if [ -f "$LIB_DIR/../hq-session.sh" ]; then
  HQ_SESSION_SH="$LIB_DIR/../hq-session.sh"
else
  HQ_SESSION_SH="$HQ_ROOT/core/scripts/hq-session.sh"
fi

EVENT="${1:-}"
if [ -z "$EVENT" ] && [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null || true)"
fi
[ -n "$EVENT" ] || EVENT="SessionStart"

THROTTLE_S="${HQ_LANES_SENIOR_MONITOR_THROTTLE_S:-180}"
case "$THROTTLE_S" in
  ''|*[!0-9]*) THROTTLE_S=180 ;;
esac

if [ ! -f "$HQ_SESSION_SH" ]; then
  echo "lanes-senior-monitor: missing hq-session.sh at $HQ_SESSION_SH" >&2
  exit 1
fi

# Resolve through hq-session.sh current — do not re-implement the precedence
# list (session-id.sh). Force the in-tree body so a hook fire does not pay
# node startup for `hq core hq-session`.
SESSION_ID="$(
  env HQ_HQ_SESSION_NO_CLI=1 HQ_ROOT="$HQ_ROOT" CLAUDE_PROJECT_DIR="$HQ_ROOT" \
    bash "$HQ_SESSION_SH" current
)"
SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -d '[:space:]')"

# No session identity: this process cannot be anyone's senior. Silent.
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

SESSION_DIR="$HQ_ROOT/workspace/sessions/$SESSION_ID"
STATE_FILE="$SESSION_DIR/lanes-senior-monitor.json"
LANES_DIR="$HQ_ROOT/workspace/lanes/lanes"

# GUARD state-not-file
# A directory (or other non-regular node) at the state path makes `mv` drop
# the temp file inside it, so last_scan and instructed never persist and
# every UserPromptSubmit re-injects.
if [ -e "$STATE_FILE" ] && [ ! -f "$STATE_FILE" ]; then
  echo "lanes-senior-monitor: state path is not a file: $STATE_FILE" >&2
  exit 1
fi
# /GUARD state-not-file

# Grok's adapter (run_master) writes master-hook stdout to a temp file and
# deletes it unread on SessionStart/UserPromptSubmit. Recording instructed[]
# there would treat a discarded delivery as done — the monitor-unknown-paths
# failure mode. Detect the harness the adapter actually exports.
hook_can_inject_context() {
  local h="${HQ_HARNESS:-${HQ_WORK_MESH_HARNESS:-${HQ_CHECKPOINT_RUNTIME:-}}}"
  case "$h" in
    grok) return 1 ;;
  esac
  return 0
}

NOW="${EPOCHSECONDS:-$(date +%s)}"
INSTRUCTED_JSON='[]'
LAST_SCAN=0
STAMP_SCAN=1

load_state() {
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$STATE_FILE" ] || return 0
  INSTRUCTED_JSON="$(jq -c 'if (.instructed | type) == "array" then .instructed else [] end' "$STATE_FILE" 2>/dev/null || echo '[]')"
  LAST_SCAN="$(jq -r '.last_scan_unix // 0' "$STATE_FILE" 2>/dev/null || echo 0)"
  case "$LAST_SCAN" in
    ''|*[!0-9]*) LAST_SCAN=0 ;;
  esac
}

write_state() {
  mkdir -p "$SESSION_DIR" || {
    echo "lanes-senior-monitor: cannot create session dir: $SESSION_DIR" >&2
    return 1
  }
  local tmp ts
  tmp="$(mktemp "$SESSION_DIR/lanes-senior-monitor.json.tmp.XXXXXX")" || {
    echo "lanes-senior-monitor: cannot create state temp file" >&2
    return 1
  }
  ts="$NOW"
  if [ "${STAMP_SCAN:-1}" != "1" ]; then
    ts=0  # empty-store-or-error: do not arm the UPS throttle
  fi
  if ! jq -n --argjson instructed "$INSTRUCTED_JSON" --argjson ts "$ts" \
      '{instructed:$instructed,last_scan_unix:$ts}' > "$tmp"; then
    rm -f "$tmp"
    echo "lanes-senior-monitor: cannot write state file" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$STATE_FILE"; then
    rm -f "$tmp"
    echo "lanes-senior-monitor: cannot replace state file" >&2
    return 1
  fi
  return 0
}

clear_throttle_state() {
  # Empty store: persist instructed so we remember what we already told,
  # but last_scan_unix=0 so UserPromptSubmit can see a lane created next.
  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  load_state
  STAMP_SCAN=0  # empty-store
  write_state
}

# GUARD refuse-symlink-store
# Check before -e: a dangling symlink is not "no lanes yet".
if [ -L "$LANES_DIR" ]; then
  echo "lanes-senior-monitor: lanes path is a symlink, refusing: $LANES_DIR" >&2
  exit 1
fi
# /GUARD refuse-symlink-store

# Missing directory: no lanes yet. Silent. Distinct from "cannot read".
# Do not arm the UPS throttle — an empty store is not a successful scan of
# a store with something in it.
if [ ! -e "$LANES_DIR" ]; then
  # GUARD empty-no-stamp
  clear_throttle_state
  exit 0
  # /GUARD empty-no-stamp
fi

if [ ! -d "$LANES_DIR" ]; then
  echo "lanes-senior-monitor: lanes path is not a directory: $LANES_DIR" >&2
  exit 1
fi

# GUARD unreadable-store
if ! ls -1A -- "$LANES_DIR" >/dev/null 2>/dev/null; then
  echo "lanes-senior-monitor: cannot read lanes directory: $LANES_DIR" >&2
  exit 1  # unreadable-store
fi
# /GUARD unreadable-store

shopt -s nullglob
lane_files=("$LANES_DIR"/*.json)
shopt -u nullglob

# Empty directory: same as missing — silent, do not arm the throttle.
if [ ${#lane_files[@]} -eq 0 ]; then
  # GUARD empty-no-stamp
  clear_throttle_state
  exit 0
  # /GUARD empty-no-stamp
fi

# jq is required only once there are records to inspect. A session that is
# senior of nothing (missing or empty store) must stay silent without jq.
if ! command -v jq >/dev/null 2>&1; then
  echo "lanes-senior-monitor: jq is required to inspect lane records" >&2
  exit 1
fi

# Malformed session-owned state is not a store failure: fail toward a scan
# (and possibly a re-instruct), never toward "already handled, stay quiet".
load_state

# SessionStart always scans: it is the first look of the session.
# Recurring events (UserPromptSubmit) share a timestamp throttle so the
# lanes store is read at most once every THROTTLE_S seconds.
if [ "$EVENT" != "SessionStart" ] && [ "$THROTTLE_S" -gt 0 ] && [ "$LAST_SCAN" -gt 0 ]; then
  AGE=$((NOW - LAST_SCAN))
  if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$THROTTLE_S" ]; then
    exit 0
  fi
fi

store_error=0
new_recs='[]'

for f in "${lane_files[@]+"${lane_files[@]}"}"; do
  [ -n "$f" ] || continue
  if [ ! -r "$f" ]; then
    echo "lanes-senior-monitor: cannot read lane record: $f" >&2
    store_error=1
    continue
  fi
  if ! jq -e 'type == "object" and (.lane_id | type == "string" and length > 0) and (.state | type == "string" and length > 0)' \
      "$f" >/dev/null 2>/dev/null; then
    echo "lanes-senior-monitor: malformed lane record: $f" >&2
    store_error=1
    continue
  fi

  rec="$(jq -c --arg sid "$SESSION_ID" '
    .
    # GUARD senior-match
    | select(.senior.kind == "session" and .senior.id == $sid)
    # /GUARD senior-match
    | {lane_id, project_id: (.project_id // ""), story_id: (.story_id // ""), state}
  ' "$f" 2>/dev/null || true)"
  [ -n "$rec" ] || continue

  rec="$(printf '%s' "$rec" | jq -c '
    # GUARD terminal-state
    select(.state == "queued" or .state == "running" or .state == "awaiting_input" or .state == "blocked")
    # /GUARD terminal-state
  ' 2>/dev/null || true)"
  [ -n "$rec" ] || continue

  lane_id="$(printf '%s' "$rec" | jq -r '.lane_id')"

  already=0
  # GUARD already-instructed
  if printf '%s' "$INSTRUCTED_JSON" | jq -e --arg id "$lane_id" 'index($id) != null' >/dev/null 2>&1; then
    already=1
  fi
  # /GUARD already-instructed
  [ "$already" -eq 0 ] || continue

  new_recs="$(jq -nc --argjson acc "$new_recs" --argjson rec "$rec" '$acc + [$rec]')"
done

new_count="$(printf '%s' "$new_recs" | jq 'length')"

# GUARD no-match-silent
if [ "$new_count" -eq 0 ]; then
  # Do not stamp last_scan on a store error: throttling a broken store
  # would hide the failure for THROTTLE_S seconds.
  if [ "$store_error" -eq 0 ]; then
    STAMP_SCAN=1
    write_state
    exit 0
  fi
  exit 1
fi
# /GUARD no-match-silent

# GUARD grok-no-false-instructed
if ! hook_can_inject_context; then
  echo "lanes-senior-monitor: this engine cannot receive additionalContext; not recording instructed" >&2
  # Observed the store; do not claim delivery. Stamp last_scan only when
  # the store itself was healthy, so UPS retries after THROTTLE_S.
  if [ "$store_error" -eq 0 ]; then
    STAMP_SCAN=1
    write_state
  fi
  exit 1
fi
# /GUARD grok-no-false-instructed

INSTRUCTED_JSON="$(jq -nc --argjson inst "$INSTRUCTED_JSON" --argjson recs "$new_recs" \
  '$inst + [ $recs[].lane_id ]')"

# GUARD no-stamp-on-store-error
# last_scan is a throttle, not a delivery receipt. A mixed store (valid
# matches plus malformed siblings) still instructs the matches, but must
# not arm the UPS throttle or the broken records stay hidden for 180s.
if [ "$store_error" -eq 0 ]; then
  STAMP_SCAN=1
else
  STAMP_SCAN=0  # store-error
fi
write_state
# /GUARD no-stamp-on-store-error

MSG="$(jq -nr --argjson lanes "$new_recs" '
  ($lanes | length) as $n
  | (if $n == 1 then "lane" else "lanes" end) as $noun
  | (
      [
        "You are the senior of \($n) \($noun). Arm a Monitor that checks each lane'\''s response every 20 minutes — its state changes, any question it raises, and its terminal state.",
        "The Monitor is session-scoped and dies with this session; ending the session leaves these lanes unwatched."
      ]
      + [ $lanes[] | "- \(.lane_id) (project \(.project_id) / story \(.story_id))" ]
    ) | join("\n")
')"

jq -nc --arg ev "$EVENT" --arg m "$MSG" \
  '{hookSpecificOutput:{hookEventName:$ev,additionalContext:$m}}'

[ "$store_error" -eq 0 ] || exit 1
exit 0
