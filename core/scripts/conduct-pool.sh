#!/usr/bin/env bash
# hq-core: public
# conduct-pool.sh — the /conduct session worker pool.
#
# /conduct hands every task to a long-lived HQ worker instead of starting a
# fresh child per task. This script is the mechanical half of that promise: it
# records which workers a session has alive and refuses to let the set grow past
# a cap. It stores the ids it is handed and nothing else — choosing which worker
# fits a task, and keeping company scopes apart, belong to the caller.
#
# Usage:
#   conduct-pool.sh [--session-id <id>] list
#   conduct-pool.sh [--session-id <id>] assign  --worker-id <id> [--task <text>]
#   conduct-pool.sh [--session-id <id>] record  --worker-id <id> --subagent-id <id>
#                                               --status running|idle|recycled [--task <text>]
#   conduct-pool.sh [--session-id <id>] recycle --worker-id <id>
#   conduct-pool.sh [--session-id <id>] clear
#
# `assign` is the only command that decides anything. It prints one JSON object:
#
#   {"action":"spawn","worker_id":"..."}                        start a new lane
#   {"action":"resume","worker_id":"...","subagent_id":"..."}   continue that lane
#   {"action":"spawn","worker_id":"...","recycled":"<other>"}   the pool was full,
#       so the least-recently-used IDLE slot was retired to make room
#
# `assign` refuses in two cases, and changes nothing in either:
#
#   exit 3  the pool is at cap and every slot is running. The caller waits for a
#           lane to finish, or retires one deliberately with `recycle`.
#   exit 4  this worker already has a lane running. Resuming would relaunch into
#           a live lane's run directory and overwrite the artifacts of a process
#           that is still working. Only an IDLE slot is resumable.
#
# A caller that ignores those exit codes spawns past the cap or on top of a live
# lane, which are the two failures this script exists to prevent.
#
# Every command that reads-modifies-writes the pool holds a per-session lock for
# the WHOLE transaction. The atomic `mv` at the end of a save is not enough on
# its own: `/conduct` dispatches independent tasks concurrently, and without the
# lock each process reads the same pre-update state, independently approves a
# spawn, and the last writer wins — twelve concurrent assigns all answered
# "spawn" against a cap of 8 and the file kept one slot.
#
# `record` refuses an unknown worker_id on purpose: every slot enters the pool
# through `assign`, which is where the cap is enforced. Letting `record` insert
# would route around it.
#
# STATE lives in the `conduct_pool` YAML list on
# workspace/sessions/<id>/meta.yaml, with fields worker_id, subagent_id, status,
# last_task, updated_at. It is deliberately NOT written through
# `hq-session.sh set`: that command replaces a single-line `key: value`, and a
# nested list cannot round-trip through it.
#
# CAP is 8 live (running + idle) slots, override with CONDUCT_POOL_CAP.
# Recycled slots are tombstones: they stay listed for provenance and do not
# count against the cap.
#
# `--task` text is a human label, not data. It is sanitized to printable
# characters with backslashes and double quotes removed and is truncated to 160
# characters, which is what lets both the YAML and the JSON above interpolate it
# without an escaping layer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
SESSIONS_DIR="$REPO_ROOT/workspace/sessions"

# shellcheck source=lib/session-id.sh
. "$SCRIPT_DIR/lib/session-id.sh"

CAP="${CONDUCT_POOL_CAP:-8}"
EXIT_CAP_FULL=3
EXIT_WORKER_BUSY=4
LOCK_HELD=0
LOCK_DIR=""

die() { echo "conduct-pool: $*" >&2; exit 1; }

usage() {
  sed -n '3,50p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//'
}

case "$CAP" in
  ''|*[!0-9]*) die "CONDUCT_POOL_CAP must be a positive integer, got '$CAP'" ;;
esac
[ "$CAP" -ge 1 ] || die "CONDUCT_POOL_CAP must be at least 1, got '$CAP'"

TMP_POOL="$(mktemp -d)"
trap 'release_lock; rm -rf "$TMP_POOL"' EXIT
SLOTS="$TMP_POOL/slots"
: > "$SLOTS"
# Records are joined with US (0x1f), not a tab. Tab is IFS whitespace, so
# `IFS=<tab> read` collapses runs of tabs into one delimiter and an empty
# subagent_id or last_task silently shifts every later field left. A control
# character cannot appear in a slot: ids are charset-validated and task text has
# \000-\037 stripped.
SEP="$(printf '\037')"

# `mkdir` is the portable atomic test-and-set: it succeeds for exactly one
# caller and needs no flock, which macOS does not ship.
#
# Staleness is judged by AGE, never by whether the recorded pid is still alive.
# A liveness check is itself a race, and a losing one: a waiter reads pid A,
# A finishes and its trap removes the directory, B takes the lock, and only then
# does the waiter's `kill -0 A` fail — so the waiter deletes the lock B is
# holding and both proceed. That is not theoretical; it let 12 concurrent
# assigns all return "spawn" against a cap of 8 in 2 of 12 test rounds.
#
# A transaction here is milliseconds, so a lock directory older than
# CONDUCT_POOL_LOCK_STALE_SECS cannot be one a live caller is holding. Waiting
# longer than CONDUCT_POOL_LOCK_WAIT_SECS is a hard error rather than a silent
# proceed: a caller that gave up and spawned anyway is the exact failure the
# lock exists to prevent.
LOCK_STALE_SECS="${CONDUCT_POOL_LOCK_STALE_SECS:-30}"
LOCK_WAIT_SECS="${CONDUCT_POOL_LOCK_WAIT_SECS:-60}"

lock_is_stale() {
  [ -d "$LOCK_DIR" ] || return 1
  local found
  found="$(find "$LOCK_DIR" -maxdepth 0 -mindepth 0 -type d \
    -newermt "-${LOCK_STALE_SECS} seconds" 2>/dev/null || true)"
  if [ -n "$found" ]; then
    return 1   # newer than the staleness window: a live holder
  fi
  # `-newermt` is GNU-only; on a find without it the probe above prints nothing
  # for a fresh lock too, so fall back to the portable minute-granularity test.
  find "$LOCK_DIR" -maxdepth 0 -mindepth 0 -type d -mmin +1 2>/dev/null | grep -q . 
}

acquire_lock() {
  local waited=0 tick=0.1 ticks_per_sec=10
  LOCK_DIR="$SESSIONS_DIR/$SESSION_ID/.conduct-pool.lock"
  mkdir -p "$(dirname "$LOCK_DIR")"
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    # The staleness probe forks `find`, so run it once a second rather than on
    # every 100ms tick: under contention that is the difference between a few
    # dozen extra processes per acquisition and a few hundred.
    if [ $((waited % ticks_per_sec)) -eq 0 ] && lock_is_stale; then
      rm -rf "$LOCK_DIR"
      continue
    fi
    waited=$((waited + 1))
    if [ "$waited" -gt $((LOCK_WAIT_SECS * ticks_per_sec)) ]; then
      die "timed out after ${LOCK_WAIT_SECS}s waiting for the pool lock at $LOCK_DIR (remove it if no conduct-pool.sh is running)"
    fi
    sleep "$tick"
  done
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  LOCK_HELD=1
}

release_lock() {
  if [ "$LOCK_HELD" = "1" ] && [ -n "$LOCK_DIR" ]; then
    rm -rf "$LOCK_DIR"
    LOCK_HELD=0
  fi
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# An id becomes a YAML scalar and a JSON string, so keep it to a conservative
# charset rather than adding an escaping layer. Rejecting here is also what
# stops this script from mangling a worker id it was handed.
valid_id() {
  case "${1:-}" in
    '') return 1 ;;
    *[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  return 0
}

sanitize_task() {
  # Fold line breaks and tabs to spaces BEFORE dropping the rest of the control
  # range, so a multi-line label collapses to "one two" rather than "onetwo".
  printf '%s' "${1:-}" \
    | tr '\n\r\t' '   ' \
    | tr -d '\000-\037' \
    | tr -d '\\"' \
    | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//' \
    | cut -c1-160
}

meta_path() { printf '%s/%s/meta.yaml' "$SESSIONS_DIR" "$SESSION_ID"; }

field_value() {
  printf '%s' "$1" | sed -e "s/^[[:space:]]*-\{0,1\}[[:space:]]*$2:[[:space:]]*//" \
                         -e 's/^"//' -e 's/"$//'
}

emit_slot() { printf '%s%s%s%s%s%s%s%s%s\n' "$1" "$SEP" "$2" "$SEP" "$3" "$SEP" "$4" "$SEP" "$5" >> "$SLOTS"; }

load_slots() {
  local meta="$1" line inblock=0 have=0 w='' s='' st='' lt='' ua=''
  : > "$SLOTS"
  [ -f "$meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$inblock" -eq 0 ]; then
      if [ "$line" = "conduct_pool:" ]; then inblock=1; fi
      continue
    fi
    case "$line" in
      " "*|$'\t'*) : ;;   # still indented, so still inside the block
      *) inblock=0; continue ;;
    esac
    case "$line" in
      "  - worker_id: "*)
        if [ "$have" -eq 1 ]; then emit_slot "$w" "$s" "$st" "$lt" "$ua"; fi
        w="$(field_value "$line" worker_id)"; s=''; st='idle'; lt=''; ua=''; have=1
        ;;
      "    subagent_id: "*) s="$(field_value "$line" subagent_id)" ;;
      "    status: "*)      st="$(field_value "$line" status)" ;;
      "    last_task: "*)   lt="$(field_value "$line" last_task)" ;;
      "    updated_at: "*)  ua="$(field_value "$line" updated_at)" ;;
      *) : ;;
    esac
  done < "$meta"
  if [ "$have" -eq 1 ]; then emit_slot "$w" "$s" "$st" "$lt" "$ua"; fi
  return 0
}

save_slots() {
  local meta="$1" tmp="$TMP_POOL/meta.new" w s st lt ua
  mkdir -p "$(dirname "$meta")"
  : > "$tmp"
  if [ -f "$meta" ]; then
    awk '
      skip == 1 { if ($0 ~ /^[ \t]/) next; skip = 0 }
      $0 == "conduct_pool:" { skip = 1; next }
      { print }
    ' "$meta" >> "$tmp"
  else
    printf 'session_id: %s\n' "$SESSION_ID" >> "$tmp"
  fi
  if [ -s "$SLOTS" ]; then
    printf 'conduct_pool:\n' >> "$tmp"
    while IFS="$SEP" read -r w s st lt ua; do
      {
        printf '  - worker_id: "%s"\n'   "$w"
        printf '    subagent_id: "%s"\n' "$s"
        printf '    status: %s\n'        "$st"
        printf '    last_task: "%s"\n'   "$lt"
        printf '    updated_at: "%s"\n'  "$ua"
      } >> "$tmp"
    done < "$SLOTS"
  fi
  mv "$tmp" "$meta"
}

find_slot() { awk -v FS="$SEP" -v w="$1" '$1 == w { print; exit }' "$SLOTS"; }
slot_field() { printf '%s' "$1" | cut -d"$SEP" -f"$2"; }
live_count() { awk -v FS="$SEP" '$3 == "running" || $3 == "idle" { n++ } END { print n+0 }' "$SLOTS"; }
live_ids() { awk -v FS="$SEP" '$3 == "running" || $3 == "idle" { print $1 }' "$SLOTS" | tr '\n' ' ' | sed -e 's/ $//'; }

# ISO-8601 UTC is fixed width, so lexicographic order is chronological order. A
# slot with no timestamp sorts first, which is the behaviour we want: an
# unstamped slot is the least recently used thing in the pool.
lru_idle() {
  awk -v FS="$SEP" -v OFS="$SEP" '$3 == "idle" { print $5, $1 }' "$SLOTS" \
    | LC_ALL=C sort | head -1 | cut -d"$SEP" -f2
}

put_slot() {
  local out="$TMP_POOL/slots.new"
  # `sub` is an awk builtin, so the lane id travels as `sid`.
  awk -v FS="$SEP" -v OFS="$SEP" -v w="$1" -v sid="$2" -v st="$3" -v t="$4" -v ts="$5" '
    $1 == w { print w, sid, st, t, ts; found = 1; next }
    { print }
    END { if (!found) print w, sid, st, t, ts }
  ' "$SLOTS" > "$out"
  mv "$out" "$SLOTS"
}

retire_slot() {
  local out="$TMP_POOL/slots.new"
  awk -v FS="$SEP" -v OFS="$SEP" -v w="$1" -v ts="$2" '
    $1 == w { print $1, "", "recycled", $4, ts; next }
    { print }
  ' "$SLOTS" > "$out"
  mv "$out" "$SLOTS"
}

cmd_list() {
  load_slots "$(meta_path)"
  awk -v FS="$SEP" '
    BEGIN { printf "["; first = 1 }
    {
      if (!first) printf ","
      first = 0
      printf "\n  {\"worker_id\":\"%s\",\"subagent_id\":\"%s\",\"status\":\"%s\",\"last_task\":\"%s\",\"updated_at\":\"%s\"}", $1, $2, $3, $4, $5
    }
    END { if (first) printf "]\n"; else printf "\n]\n" }
  ' "$SLOTS"
}

cmd_assign() {
  local wid="$1" task="$2" meta existing status sub prev now retired
  valid_id "$wid" || die "assign: --worker-id must be non-empty and match [A-Za-z0-9._:-]"
  meta="$(meta_path)"
  acquire_lock
  load_slots "$meta"
  now="$(now_utc)"
  existing="$(find_slot "$wid")"

  if [ -n "$existing" ]; then
    status="$(slot_field "$existing" 3)"
    sub="$(slot_field "$existing" 2)"
    prev="$(slot_field "$existing" 4)"
    [ -n "$task" ] || task="$prev"
    if [ "$status" = "running" ]; then
      # Resuming here would relaunch into the run directory of a lane that is
      # still working and overwrite its artifacts mid-flight.
      echo "conduct-pool: worker '$wid' already has a lane running (run id: ${sub:-unrecorded})." >&2
      echo "conduct-pool: wait for it to report and mark it idle, or retire it with: conduct-pool.sh recycle --worker-id $wid" >&2
      exit "$EXIT_WORKER_BUSY"
    fi
    if [ "$status" = "idle" ]; then
      # Idle and still in the pool: the same worker keeps the same lane. This is
      # the case the pool exists for.
      put_slot "$wid" "$sub" running "$task" "$now"
      save_slots "$meta"
      release_lock
      printf '{"action":"resume","worker_id":"%s","subagent_id":"%s"}\n' "$wid" "$sub"
      return 0
    fi
  fi

  # Unknown worker, or one whose slot was retired: this assign adds a live slot,
  # so the cap applies.
  if [ "$(live_count)" -ge "$CAP" ]; then
    retired="$(lru_idle)"
    if [ -z "$retired" ]; then
      echo "conduct-pool: pool is full at cap $CAP and every slot is running — cannot start '$wid'." >&2
      echo "conduct-pool: live workers: $(live_ids)" >&2
      echo "conduct-pool: wait for one to report, or retire one with: conduct-pool.sh recycle --worker-id <id>" >&2
      exit "$EXIT_CAP_FULL"
    fi
    retire_slot "$retired" "$now"
    put_slot "$wid" "" running "$task" "$now"
    save_slots "$meta"
    release_lock
    printf '{"action":"spawn","worker_id":"%s","recycled":"%s"}\n' "$wid" "$retired"
    return 0
  fi

  put_slot "$wid" "" running "$task" "$now"
  save_slots "$meta"
  release_lock
  printf '{"action":"spawn","worker_id":"%s"}\n' "$wid"
}

cmd_record() {
  local wid="$1" sub="$2" status="$3" task="$4" meta existing prev
  valid_id "$wid" || die "record: --worker-id must be non-empty and match [A-Za-z0-9._:-]"
  valid_id "$sub" || die "record: --subagent-id must be non-empty and match [A-Za-z0-9._:-]"
  case "$status" in
    running|idle|recycled) : ;;
    *) die "record: --status must be running, idle, or recycled (got '${status:-}')" ;;
  esac
  meta="$(meta_path)"
  acquire_lock
  load_slots "$meta"
  existing="$(find_slot "$wid")"
  [ -n "$existing" ] || die "record: no pool slot for '$wid' — run 'assign --worker-id $wid' first (assign is where the cap is enforced)"
  prev="$(slot_field "$existing" 4)"
  [ -n "$task" ] || task="$prev"
  if [ "$status" = "recycled" ]; then sub=""; fi
  put_slot "$wid" "$sub" "$status" "$task" "$(now_utc)"
  save_slots "$meta"
}

cmd_recycle() {
  local wid="$1" meta existing
  valid_id "$wid" || die "recycle: --worker-id must be non-empty and match [A-Za-z0-9._:-]"
  meta="$(meta_path)"
  acquire_lock
  load_slots "$meta"
  existing="$(find_slot "$wid")"
  [ -n "$existing" ] || die "recycle: no pool slot for '$wid'"
  retire_slot "$wid" "$(now_utc)"
  save_slots "$meta"
}

cmd_clear() {
  local meta
  meta="$(meta_path)"
  acquire_lock
  load_slots "$meta"
  : > "$SLOTS"
  save_slots "$meta"
}

SESSION_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done

[ $# -gt 0 ] || { usage >&2; exit 1; }
SUBCOMMAND="$1"; shift

if [ -z "$SESSION_ID" ]; then
  SESSION_ID="$(session_id_resolve "$REPO_ROOT")"
fi
[ -n "$SESSION_ID" ] || die "no current session — pass --session-id <id> or set HQ_SESSION_ID"
session_id_is_valid "$SESSION_ID" || die "invalid session id: '$SESSION_ID'"

ARG_WORKER=""
ARG_SUBAGENT=""
ARG_STATUS=""
ARG_TASK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --worker-id)   ARG_WORKER="${2:-}"; shift 2 ;;
    --subagent-id) ARG_SUBAGENT="${2:-}"; shift 2 ;;
    --status)      ARG_STATUS="${2:-}"; shift 2 ;;
    --task)        ARG_TASK="$(sanitize_task "${2:-}")"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$SUBCOMMAND" in
  list)    cmd_list ;;
  assign)  cmd_assign "$ARG_WORKER" "$ARG_TASK" ;;
  record)  cmd_record "$ARG_WORKER" "$ARG_SUBAGENT" "$ARG_STATUS" "$ARG_TASK" ;;
  recycle) cmd_recycle "$ARG_WORKER" ;;
  clear)   cmd_clear ;;
  *)       usage >&2; exit 1 ;;
esac
