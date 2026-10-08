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
#                                               [--envelope <file>]
#   conduct-pool.sh [--session-id <id>] record  --worker-id <id> --subagent-id <id>
#                                               --status running|waiting|idle
#                                               [--pid <pid> --run-dir <dir>] [--task <text>]
#   conduct-pool.sh [--session-id <id>] recycle --worker-id <id> [--force]
#   conduct-pool.sh [--session-id <id>] cancel  --worker-id <id>
#   conduct-pool.sh [--session-id <id>] clear
#   conduct-pool.sh [--session-id <id>] decisions
#   conduct-pool.sh [--session-id <id>] reconcile
#
# A slot moves through five states, and every verb below keys on the status —
# never on whether some other field happens to be filled in:
#
#   claimed   `assign` granted the lane; nothing is dispatched into it yet
#   running   `record --status running` attached a sub-agent; work is live
#   waiting   a loop-mode lane (workflow-runner --loop) whose process is alive
#             and whose queue is empty. It is live: it counts against the cap
#             and is never retired to make room
#   idle      the lane's process is gone; the next assign resumes it
#   recycled  retired. A tombstone, kept for provenance, not counted against cap
#
# LOOP-MODE slots are the ones recorded with `--pid` and `--run-dir`. Their
# queue is <run-dir>/inbox/pending/. Every `list` and `assign` reconciles them
# against the process before deciding anything:
#
#   pid dead                       -> idle (pid cleared; the queue is kept)
#   pid alive, pending/ and active/ empty -> waiting
#   pid alive, anything queued or active  -> running
#
# A loop lane that stalls restarts itself in place (workflow-runner.mjs "Phase
# deadlines"): the new process rewrites <run-dir>/loop.json with its pid. When
# the recorded pid is dead and loop.json names a live pid, reconcile adopts it,
# so the slot, its worker id and its queue stay the same across the restart.
#
# A lane that stalls twice on the same phase stops and appends a decision item
# to <run-dir>/decisions.jsonl. Every `list`, `assign` and `decisions` forwards
# new items to workspace/sessions/<id>/decisions.jsonl (the file the parent
# session reads; `decisions` prints it). The slot goes idle by the dead-pid rule
# with its queue kept; other slots are unaffected.
#
# Assigning to a waiting or running loop-mode slot ENQUEUES: the `--envelope`
# file is copied into the lane's pending/ (tmp + rename, conduct-inbox naming)
# and nothing is spawned, so the live process takes it. Without `--envelope`
# such an assign is refused with exit 4. Assigning to an idle slot behaves as it
# always has.
#
# `record` does NOT accept `--status recycled`. Retirement is `recycle` or
# `cancel`, both of which enforce the running-lane guard and purge the slot's
# persisted handoffs; a `record` path into the same state would route around
# both.
#
# `assign` is the only command that decides anything. It prints one JSON object:
#
#   {"action":"spawn","worker_id":"..."}                        start a new lane
#   {"action":"resume","worker_id":"...","subagent_id":"..."}   continue that lane
#   {"action":"spawn","worker_id":"...","recycled":"<other>"}   the pool was full,
#       so the least-recently-used IDLE slot was retired to make room
#   {"action":"enqueue","worker_id":"...","pid":N,"queued":"<path>","queue_depth":N}
#       a live loop-mode lane took the envelope; spawn nothing
#
# `cancel` is the counterpart to an `assign` you decided not to act on. A caller
# that claims a lane and backs out — most often because the slot's ownership
# stamp names another company or project — needs to release it, and cannot use
# `recycle`, which refuses a dispatched lane. `cancel` covers exactly that
# window: it retires a slot while it is still `claimed`, and refuses once
# `record --status running` has moved it on.
#
# It keys on the status deliberately. An empty `subagent_id` would NOT have
# worked as the test: a RESUME claim keeps the previous lane's id while it waits
# to be dispatched, so keying on emptiness refuses exactly the cross-tenant reset
# this verb exists for.
#
# Refusals, none of which change anything:
#
#   exit 3  the pool is at cap and no slot is idle. Wait for a lane to report and
#           be marked idle. Retiring a running one does not stop its sub-agent,
#           so `recycle` refuses it; only after you have stopped it does
#           `recycle --force` apply.
#
#   exit 4  this worker already has a lane `running` or `claimed`. Resuming a
#           running one would relaunch into the run directory of a process that
#           is still working and overwrite its artifacts; a claimed one is held
#           by another caller about to dispatch. Only an IDLE slot is resumable.
#
#   exit 5  `recycle` was asked to retire a RUNNING or WAITING lane, or `cancel` was asked
#           to drop a lane that is not `claimed`. Retiring a live lane frees its
#           slot in the pool but does NOT stop the sub-agent: it keeps working,
#           so the real number of live children exceeds the cap and the old lane
#           can write on top of whatever claims the slot next. Confirm the lane
#           finished, or stop it, then re-run `recycle` with --force.
#
#   exit 6  the MACHINE is at its lane cap. `assign` counts the running and
#           claimed slots of every session pool under workspace/sessions/*/
#           (this one included) and refuses a new claim when the total would
#           exceed CONDUCT_MACHINE_CAP (default 16; 0 disables the check). A slot
#           whose recorded pid is dead is not counted. The refusal names the
#           count, the cap and the sessions holding the most slots. An enqueue
#           into a live loop lane adds no lane and is never refused here.
#
# `reconcile` marks idle every `running` slot of a ONE-SHOT lane (no run_dir
# recorded) whose lane has exited: its run dir
# workspace/tmp/workflow-runner/<session>/<subagent_id>/ has `CONDUCT_EXIT=` in
# lane.log and its lane.pid and runner.pid are dead. It never touches a loop
# lane, a lane with no marker, or a lane whose pid is alive, and it never
# recycles. It prints one line per slot it changed. The waiter in
# lane-dispatch-protocol.md section 5 records the slot idle itself; reconcile
# catches the lanes whose waiter was swept.
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
# Loop-mode slots also carry pid and run_dir. `list` adds pid, run_dir and
# queue_depth (files in <run_dir>/inbox/pending/) to every slot.
#
# CAP is 8 live (claimed + running + waiting + idle) slots, override with
# CONDUCT_POOL_CAP.
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
MACHINE_CAP="${CONDUCT_MACHINE_CAP:-16}"
EXIT_CAP_FULL=3
EXIT_MACHINE_CAP=6
EXIT_WORKER_BUSY=4
EXIT_LANE_RUNNING=5
LOCK_HELD=0
LOCK_DIR=""

die() { echo "conduct-pool: $*" >&2; exit 1; }

# Print the whole header comment (line 3 up to the first non-comment line), so
# the usage text cannot be cut off again when the header grows.
usage() {
  awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

case "$CAP" in
  ''|*[!0-9]*) die "CONDUCT_POOL_CAP must be a positive integer, got '$CAP'" ;;
esac
[ "$CAP" -ge 1 ] || die "CONDUCT_POOL_CAP must be at least 1, got '$CAP'"
case "$MACHINE_CAP" in
  ''|*[!0-9]*) die "CONDUCT_MACHINE_CAP must be a non-negative integer, got '$MACHINE_CAP'" ;;
esac

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

# A run dir becomes a YAML scalar and a JSON string too. It is a path, so the id
# charset is too strict; reject only what would need escaping.
valid_run_dir() {
  case "${1:-}" in
    /*) : ;;
    *) return 1 ;;
  esac
  case "$1" in
    *'"'*|*'\'*) return 1 ;;
  esac
  [ "$(printf '%s' "$1" | tr -d '\000-\037')" = "$1" ]
}

valid_pid() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ]
}

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# Files a loop lane has not yet claimed. Dotfiles are in-flight writes.
dir_count() {
  [ -d "$1" ] || { echo 0; return 0; }
  find "$1" -mindepth 1 -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' '
}
queue_depth() { [ -n "${1:-}" ] || { echo 0; return 0; }; dir_count "$1/inbox/pending"; }

emit_slot() {
  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s\n' "$1" "$SEP" "$2" "$SEP" "$3" "$SEP" "$4" "$SEP" "$5" \
    "$SEP" "${6:-}" "$SEP" "${7:-}" >> "$SLOTS"
}

load_slots() {
  local meta="$1" line inblock=0 have=0 w='' s='' st='' lt='' ua='' pd='' rd=''
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
        if [ "$have" -eq 1 ]; then emit_slot "$w" "$s" "$st" "$lt" "$ua" "$pd" "$rd"; fi
        w="$(field_value "$line" worker_id)"; s=''; st='idle'; lt=''; ua=''; pd=''; rd=''; have=1
        ;;
      "    subagent_id: "*) s="$(field_value "$line" subagent_id)" ;;
      "    status: "*)      st="$(field_value "$line" status)" ;;
      "    last_task: "*)   lt="$(field_value "$line" last_task)" ;;
      "    updated_at: "*)  ua="$(field_value "$line" updated_at)" ;;
      "    pid: "*)         pd="$(field_value "$line" pid)" ;;
      "    run_dir: "*)     rd="$(field_value "$line" run_dir)" ;;
      *) : ;;
    esac
  done < "$meta"
  if [ "$have" -eq 1 ]; then emit_slot "$w" "$s" "$st" "$lt" "$ua" "$pd" "$rd"; fi
  return 0
}

save_slots() {
  local meta="$1" tmp="$TMP_POOL/meta.new" w s st lt ua pd rd
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
    while IFS="$SEP" read -r w s st lt ua pd rd; do
      {
        printf '  - worker_id: "%s"\n'   "$w"
        printf '    subagent_id: "%s"\n' "$s"
        printf '    status: %s\n'        "$st"
        printf '    last_task: "%s"\n'   "$lt"
        printf '    updated_at: "%s"\n'  "$ua"
        if [ -n "$rd" ]; then
          printf '    pid: "%s"\n'       "$pd"
          printf '    run_dir: "%s"\n'   "$rd"
        fi
      } >> "$tmp"
    done < "$SLOTS"
  fi
  mv "$tmp" "$meta"
}

find_slot() { awk -v FS="$SEP" -v w="$1" '$1 == w { print; exit }' "$SLOTS"; }
slot_field() { printf '%s' "$1" | cut -d"$SEP" -f"$2"; }
# A slot is live from the moment it is claimed. `claimed` is the window between
# `assign` granting a lane and `record` attaching a sub-agent to it: the slot is
# held and counts against the cap, but nothing is running in it yet. Keeping that
# distinct from `running` is what lets `cancel` tell "I claimed this and backed
# out" apart from "a sub-agent is working in here", without having to take the
# caller's word for it.
live_count() { awk -v FS="$SEP" '$3 == "running" || $3 == "claimed" || $3 == "waiting" || $3 == "idle" { n++ } END { print n+0 }' "$SLOTS"; }
live_ids() { awk -v FS="$SEP" '$3 == "running" || $3 == "claimed" || $3 == "waiting" || $3 == "idle" { print $1 }' "$SLOTS" | tr '\n' ' ' | sed -e 's/ $//'; }

# ISO-8601 UTC is fixed width, so lexicographic order is chronological order. A
# slot with no timestamp sorts first, which is the behaviour we want: an
# unstamped slot is the least recently used thing in the pool.
lru_idle() {
  awk -v FS="$SEP" -v OFS="$SEP" '$3 == "idle" { print $5, $1 }' "$SLOTS" \
    | LC_ALL=C sort | head -1 | cut -d"$SEP" -f2
}

# put_slot <w> <sub> <status> <task> <ts> [<pid> <run_dir>]
# With five arguments an existing slot keeps its pid and run_dir; pass both to
# replace them (empty strings clear them).
put_slot() {
  local out="$TMP_POOL/slots.new" keep=1
  [ "$#" -lt 6 ] || keep=0
  # `sub` is an awk builtin, so the lane id travels as `sid`.
  awk -v FS="$SEP" -v OFS="$SEP" -v w="$1" -v sid="$2" -v st="$3" -v t="$4" -v ts="$5" \
      -v pd="${6:-}" -v rd="${7:-}" -v keep="$keep" '
    $1 == w {
      if (keep == 1) { pd = $6; rd = $7 }
      print w, sid, st, t, ts, pd, rd; found = 1; next
    }
    { print }
    END { if (!found) print w, sid, st, t, ts, pd, rd }
  ' "$SLOTS" > "$out"
  mv "$out" "$SLOTS"
}

# Bring every loop-mode slot that claims to be live in line with its process:
# a dead pid is idle (its queue is left exactly as it is, for whatever resumes
# the lane), a live one is waiting or running by whether it has work. Called
# under the lock by every verb that reads or decides on status.
reconcile_loop_slots() {
  local out="$TMP_POOL/slots.rec" w s st lt ua pd rd want changed=0 now lp
  now="$(now_utc)"
  : > "$out"
  while IFS="$SEP" read -r w s st lt ua pd rd; do
    want="$st"
    if [ -n "$rd" ]; then forward_decisions "$rd"; fi
    # A lane that restarted itself in place after a stall has a new pid.
    if [ -n "$rd" ] && { [ "$st" = "waiting" ] || [ "$st" = "running" ]; } && ! pid_alive "$pd"; then
      lp="$(loop_json_pid "$rd")"
      if [ -n "$lp" ] && [ "$lp" != "$pd" ] && pid_alive "$lp"; then pd="$lp"; changed=1; fi
    fi
    if [ -n "$rd" ] && { [ "$st" = "waiting" ] || [ "$st" = "running" ]; }; then
      if ! pid_alive "$pd"; then
        want="idle"; pd=""
      elif [ "$(queue_depth "$rd")" -eq 0 ] && [ "$(dir_count "$rd/inbox/active")" -eq 0 ]; then
        want="waiting"
      else
        want="running"
      fi
    fi
    if [ "$want" != "$st" ]; then st="$want"; ua="$now"; changed=1; fi
    printf '%s%s%s%s%s%s%s%s%s%s%s%s%s\n' "$w" "$SEP" "$s" "$SEP" "$st" "$SEP" "$lt" "$SEP" "$ua" \
      "$SEP" "$pd" "$SEP" "$rd" >> "$out"
  done < "$SLOTS"
  mv "$out" "$SLOTS"
  [ "$changed" -eq 1 ]
}

# The pid a loop lane last wrote to <run-dir>/loop.json, or nothing.
loop_json_pid() {
  [ -f "$1/loop.json" ] || return 0
  sed -n 's/^[[:space:]]*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1/loop.json" | head -1
}

decisions_file() { printf '%s/%s/decisions.jsonl' "$SESSIONS_DIR" "$SESSION_ID"; }

# Append decision items a lane wrote since the last call to the session's
# decisions.jsonl. <run-dir>/decisions.forwarded holds the count already sent.
forward_decisions() {
  local rd="$1" src n done_n dest
  src="$rd/decisions.jsonl"
  [ -f "$src" ] || return 0
  n="$(wc -l < "$src" | tr -d ' ')"
  done_n="$(cat "$rd/decisions.forwarded" 2>/dev/null || echo 0)"
  case "$done_n" in ''|*[!0-9]*) done_n=0 ;; esac
  [ "$n" -gt "$done_n" ] || return 0
  dest="$(decisions_file)"
  mkdir -p "$(dirname "$dest")"
  tail -n "+$((done_n + 1))" "$src" | head -n "$((n - done_n))" >> "$dest"
  printf '%s\n' "$n" > "$rd/decisions.forwarded"
}

# Copy an envelope into a loop lane's queue the way conduct-inbox.sh send does:
# written beside pending/ and renamed in, so the lane never reads half a file.
enqueue_envelope() {
  local rd="$1" src="$2" pending tmp target
  pending="$rd/inbox/pending"
  mkdir -p "$pending"
  target="$pending/$(date -u +%Y%m%d%H%M%S)-$$.msg"
  tmp="$(mktemp "$rd/inbox/.send.XXXXXX")"
  cat "$src" > "$tmp"
  mv "$tmp" "$target"
  printf '%s' "$target"
}

# A retired slot must not be able to hand its history back. Recycling is how a
# fat lane is discarded, so leaving its handoff file in place means the next
# claim of the same worker id — which passes the ownership check, because it is
# the same company and project — reads back the entire transcript the recycle
# was meant to drop, and it grows without bound across recycles.
purge_slot_dir() {
  local dir="$SESSIONS_DIR/$SESSION_ID/pool/$1"
  [ -d "$dir" ] || return 0
  rm -f "$dir/handoffs.jsonl" "$dir/owner.json"
}

retire_slot() {
  local out="$TMP_POOL/slots.new"
  awk -v FS="$SEP" -v OFS="$SEP" -v w="$1" -v ts="$2" '
    $1 == w { print $1, "", "recycled", $4, ts; next }
    { print }
  ' "$SLOTS" > "$out"
  mv "$out" "$SLOTS"
}

# Machine-wide lane count. Every session pool's running and claimed slots count,
# except a slot whose recorded pid is dead (pid_alive, the same check reconcile
# uses). This session's slots come from the in-memory $SLOTS, which reconcile has
# just brought up to date; every other session is read from its meta.yaml
# without its lock, since the count is advisory and a read never writes.
# Prints "<session> <n>" per session with at least one counted slot.
machine_counts() {
  local meta sid line inblock st pd n
  awk -v FS="$SEP" '($3 == "running" || $3 == "claimed") { print $6 }' "$SLOTS" > "$TMP_POOL/own.pids"
  n=0
  while IFS= read -r pd || [ -n "$pd" ]; do
    if [ -n "$pd" ] && ! pid_alive "$pd"; then continue; fi
    n=$((n + 1))
  done < "$TMP_POOL/own.pids"
  [ "$n" -eq 0 ] || printf '%s %s\n' "$SESSION_ID" "$n"
  for meta in "$SESSIONS_DIR"/*/meta.yaml; do
    [ -f "$meta" ] || continue
    sid="$(basename "$(dirname "$meta")")"
    [ "$sid" = "$SESSION_ID" ] && continue
    n=0; inblock=0; st=''; pd=''
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$inblock" -eq 0 ]; then
        [ "$line" = "conduct_pool:" ] && inblock=1
        continue
      fi
      case "$line" in
        " "*|$'\t'*) : ;;
        *) break ;;
      esac
      case "$line" in
        "  - worker_id: "*)
          if [ "$st" = running ] || [ "$st" = claimed ]; then
            if [ -z "$pd" ] || pid_alive "$pd"; then n=$((n + 1)); fi
          fi
          st=''; pd='' ;;
        "    status: "*) st="$(field_value "$line" status)" ;;
        "    pid: "*)    pd="$(field_value "$line" pid)" ;;
      esac
    done < "$meta"
    if [ "$st" = running ] || [ "$st" = claimed ]; then
      if [ -z "$pd" ] || pid_alive "$pd"; then n=$((n + 1)); fi
    fi
    [ "$n" -eq 0 ] || printf '%s %s\n' "$sid" "$n"
  done
}

# Refuse (exit 6, lock released) when one more claimed slot would put the
# machine over CONDUCT_MACHINE_CAP. 0 disables the check.
machine_cap_check() {
  local wid="$1" counts total top
  [ "$MACHINE_CAP" -gt 0 ] || return 0
  counts="$(machine_counts)"
  total="$(printf '%s\n' "$counts" | awk 'NF == 2 { t += $2 } END { print t+0 }')"
  [ $((total + 1)) -gt "$MACHINE_CAP" ] || return 0
  top="$(printf '%s\n' "$counts" | awk 'NF == 2' | LC_ALL=C sort -k2,2nr -k1,1 | head -3 \
    | awk '{ printf "%s%s (%s)", (NR > 1 ? ", " : ""), $1, $2 }')"
  release_lock
  echo "conduct-pool: machine lane cap reached: $total running or claimed lane(s) across every session, cap $MACHINE_CAP (CONDUCT_MACHINE_CAP) — cannot start '$wid'." >&2
  echo "conduct-pool: sessions holding the most: $top" >&2
  echo "conduct-pool: wait for lanes to finish, or raise CONDUCT_MACHINE_CAP (0 disables the check)." >&2
  exit "$EXIT_MACHINE_CAP"
}

cmd_list() {
  local meta rows="$TMP_POOL/list.rows" w s st lt ua pd rd
  meta="$(meta_path)"
  # Listing reconciles loop-mode slots, which can write, so it takes the lock.
  acquire_lock
  load_slots "$meta"
  if reconcile_loop_slots; then save_slots "$meta"; fi
  release_lock
  : > "$rows"
  while IFS="$SEP" read -r w s st lt ua pd rd; do
    printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' "$w" "$SEP" "$s" "$SEP" "$st" "$SEP" "$lt" "$SEP" "$ua" \
      "$SEP" "$pd" "$SEP" "$rd" "$SEP" "$(queue_depth "$rd")" >> "$rows"
  done < "$SLOTS"
  awk -v FS="$SEP" '
    BEGIN { printf "["; first = 1 }
    {
      if (!first) printf ","
      first = 0
      printf "\n  {\"worker_id\":\"%s\",\"subagent_id\":\"%s\",\"status\":\"%s\",\"last_task\":\"%s\",\"updated_at\":\"%s\",\"pid\":%s,\"run_dir\":\"%s\",\"queue_depth\":%d}", $1, $2, $3, $4, $5, ($6 == "" ? "null" : $6), $7, $8
    }
    END { if (first) printf "]\n"; else printf "\n]\n" }
  ' "$rows"
}

cmd_assign() {
  local wid="$1" task="$2" envelope="$3" meta existing status sub prev now retired pd rd queued
  valid_id "$wid" || die "assign: --worker-id must be non-empty and match [A-Za-z0-9._:-]"
  if [ -n "$envelope" ]; then
    [ -f "$envelope" ] && [ -s "$envelope" ] || die "assign: --envelope must be a non-empty file, got '$envelope'"
  fi
  meta="$(meta_path)"
  acquire_lock
  load_slots "$meta"
  if reconcile_loop_slots; then save_slots "$meta"; fi
  now="$(now_utc)"
  existing="$(find_slot "$wid")"

  if [ -n "$existing" ]; then
    status="$(slot_field "$existing" 3)"
    sub="$(slot_field "$existing" 2)"
    prev="$(slot_field "$existing" 4)"
    pd="$(slot_field "$existing" 6)"
    rd="$(slot_field "$existing" 7)"
    [ -n "$task" ] || task="$prev"
    # A live loop-mode lane takes new work through its queue. Reconcile above
    # has just confirmed its pid is alive, so spawning here would put a second
    # process on the same run directory.
    if [ -n "$rd" ] && { [ "$status" = "waiting" ] || [ "$status" = "running" ]; }; then
      if [ -z "$envelope" ]; then
        echo "conduct-pool: worker '$wid' is a live loop lane ($status, pid $pd). Pass --envelope <file>" >&2
        echo "conduct-pool: to queue the phase into $rd/inbox/pending/; never spawn a second process." >&2
        exit "$EXIT_WORKER_BUSY"
      fi
      queued="$(enqueue_envelope "$rd" "$envelope")"
      put_slot "$wid" "$sub" running "$task" "$now"
      save_slots "$meta"
      release_lock
      printf '{"action":"enqueue","worker_id":"%s","pid":%s,"queued":"%s","queue_depth":%d}\n' \
        "$wid" "$pd" "$queued" "$(queue_depth "$rd")"
      return 0
    fi
    if [ "$status" = "running" ] || [ "$status" = "claimed" ]; then
      # Resuming here would relaunch into the run directory of a lane that is
      # still working and overwrite its artifacts mid-flight. A `claimed` lane is
      # equally unavailable: another caller holds it and is about to dispatch.
      echo "conduct-pool: worker '$wid' already has a lane $status (run id: ${sub:-unrecorded})." >&2
      if [ "$status" = "claimed" ]; then
        echo "conduct-pool: another caller claimed it and has not dispatched yet. Wait, or if that" >&2
        echo "conduct-pool: claim was yours and you backed out: conduct-pool.sh cancel --worker-id $wid" >&2
      else
        echo "conduct-pool: wait for it to report and mark it idle. Retiring it does NOT stop the" >&2
        echo "conduct-pool: sub-agent, so only after you have stopped it: recycle --worker-id $wid --force" >&2
      fi
      exit "$EXIT_WORKER_BUSY"
    fi
    if [ "$status" = "idle" ]; then
      # Idle and still in the pool: the same worker keeps the same lane. This is
      # the case the pool exists for.
      machine_cap_check "$wid"
      put_slot "$wid" "$sub" claimed "$task" "$now"
      save_slots "$meta"
      release_lock
      printf '{"action":"resume","worker_id":"%s","subagent_id":"%s"}\n' "$wid" "$sub"
      return 0
    fi
  fi

  # Unknown worker, or one whose slot was retired: this assign adds a live slot,
  # so the cap applies.
  machine_cap_check "$wid"
  if [ "$(live_count)" -ge "$CAP" ]; then
    retired="$(lru_idle)"
    if [ -z "$retired" ]; then
      echo "conduct-pool: pool is full at cap $CAP and no slot is idle — cannot start '$wid'." >&2
      echo "conduct-pool: live workers: $(live_ids)" >&2
      echo "conduct-pool: wait for one to report and be marked idle. Retiring a running lane does" >&2
      echo "conduct-pool: NOT stop its sub-agent, so 'recycle' refuses one; only after you have" >&2
      echo "conduct-pool: stopped it does 'recycle --worker-id <id> --force' apply." >&2
      exit "$EXIT_CAP_FULL"
    fi
    retire_slot "$retired" "$now"
    purge_slot_dir "$retired"
    put_slot "$wid" "" claimed "$task" "$now"
    save_slots "$meta"
    release_lock
    printf '{"action":"spawn","worker_id":"%s","recycled":"%s"}\n' "$wid" "$retired"
    return 0
  fi

  put_slot "$wid" "" claimed "$task" "$now"
  save_slots "$meta"
  release_lock
  printf '{"action":"spawn","worker_id":"%s"}\n' "$wid"
}

cmd_record() {
  local wid="$1" sub="$2" status="$3" task="$4" pid="$5" rundir="$6" meta existing prev
  valid_id "$wid" || die "record: --worker-id must be non-empty and match [A-Za-z0-9._:-]"
  valid_id "$sub" || die "record: --subagent-id must be non-empty and match [A-Za-z0-9._:-]"
  # --pid and --run-dir travel together: they are what makes a slot loop-mode.
  if [ -n "$pid" ] || [ -n "$rundir" ]; then
    valid_pid "$pid" || die "record: --pid must be a positive integer (got '${pid:-}')"
    valid_run_dir "$rundir" || die "record: --run-dir must be an absolute path without quotes, backslashes or control characters"
  fi
  case "$status" in
    waiting)
      [ -n "$rundir" ] || die "record: --status waiting is for a loop-mode lane; pass --pid and --run-dir" ;;
    running|idle) : ;;
    recycled)
      # Retirement is not a status you can assert your way into. This path used
      # to mark a running slot recycled and clear its sub-agent id directly,
      # which skipped the running-lane guard AND the handoff purge — a caller
      # could retire a live lane and be granted its replacement while the
      # original kept working.
      die "record: --status recycled is not accepted. Retire a lane with 'recycle --worker-id $wid' (add --force only after you have stopped a running one), or 'cancel --worker-id $wid' for a claim you never dispatched." ;;
    *) die "record: --status must be running, waiting or idle (got '${status:-}')" ;;
  esac
  meta="$(meta_path)"
  acquire_lock
  load_slots "$meta"
  existing="$(find_slot "$wid")"
  [ -n "$existing" ] || die "record: no pool slot for '$wid' — run 'assign --worker-id $wid' first (assign is where the cap is enforced)"
  prev="$(slot_field "$existing" 4)"
  [ -n "$task" ] || task="$prev"
  if [ -n "$rundir" ]; then
    put_slot "$wid" "$sub" "$status" "$task" "$(now_utc)" "$pid" "$rundir"
  else
    put_slot "$wid" "$sub" "$status" "$task" "$(now_utc)"
  fi
  save_slots "$meta"
}

# Retiring a slot is a pool operation, not a process operation: it frees the
# entry and leaves the sub-agent alone. For an idle slot that is exactly right.
# For a running one it is a lie the rest of the system believes — the cap is
# enforced against the pool, so a retired-but-live lane puts the real child
# count over the cap, and whatever claims the slot next shares a run directory
# with a process still writing to it. Refuse unless the caller says it has
# already confirmed the lane stopped.
cmd_recycle() {
  local wid="$1" force="$2" meta existing status
  valid_id "$wid" || die "recycle: --worker-id must be non-empty and match [A-Za-z0-9._:-]"
  meta="$(meta_path)"
  acquire_lock
  load_slots "$meta"
  reconcile_loop_slots || :
  existing="$(find_slot "$wid")"
  [ -n "$existing" ] || die "recycle: no pool slot for '$wid'"
  status="$(slot_field "$existing" 3)"
  # `claimed` has no sub-agent, so retiring it is safe and stays allowed. Only a
  # dispatched lane is refused.
  if { [ "$status" = "running" ] || [ "$status" = "waiting" ]; } && [ "$force" != "1" ]; then
    echo "conduct-pool: recycle: lane '$wid' is still $status." >&2
    echo "conduct-pool: retiring it frees the slot but does not stop the sub-agent, so the" >&2
    echo "conduct-pool: real child count would exceed the cap and the next claimant would share" >&2
    echo "conduct-pool: a run directory with a live writer." >&2
    echo "conduct-pool: wait for it and mark it idle, or stop it and re-run with --force." >&2
    release_lock
    exit "$EXIT_LANE_RUNNING"
  fi
  retire_slot "$wid" "$(now_utc)"
  save_slots "$meta"
  purge_slot_dir "$wid"
}

# Retire a claim that was never dispatched. The `claimed` status is the evidence
# and it is a fact this script owns: `assign` writes it, and only
# `record --status running` moves a lane out of it. An empty subagent_id would
# NOT have worked — a resume claim keeps the previous lane's id while it waits to
# be dispatched, so keying on emptiness would have refused exactly the
# cross-tenant reset this verb exists for.
cmd_cancel() {
  local wid="$1" meta existing status sub
  valid_id "$wid" || die "cancel: --worker-id must be non-empty and match [A-Za-z0-9._:-]"
  meta="$(meta_path)"
  acquire_lock
  load_slots "$meta"
  existing="$(find_slot "$wid")"
  [ -n "$existing" ] || die "cancel: no pool slot for '$wid'"
  status="$(slot_field "$existing" 3)"
  sub="$(slot_field "$existing" 2)"
  if [ "$status" != "claimed" ]; then
    echo "conduct-pool: cancel: lane '$wid' is '$status', not 'claimed'." >&2
    echo "conduct-pool: cancel only drops a claim between assign and dispatch. A running lane" >&2
    echo "conduct-pool: (sub-agent: ${sub:-unrecorded}) must be waited out and marked idle, or" >&2
    echo "conduct-pool: stopped and retired with: recycle --worker-id $wid --force" >&2
    echo "conduct-pool: an idle lane is retired with: recycle --worker-id $wid" >&2
    release_lock
    exit "$EXIT_LANE_RUNNING"
  fi
  retire_slot "$wid" "$(now_utc)"
  save_slots "$meta"
  purge_slot_dir "$wid"
}

cmd_decisions() {
  local meta dest
  meta="$(meta_path)"
  acquire_lock
  load_slots "$meta"
  if reconcile_loop_slots; then save_slots "$meta"; fi
  release_lock
  dest="$(decisions_file)"
  [ -f "$dest" ] && cat "$dest"
  return 0
}

# One-shot lanes are recorded without a run_dir; their run dir is minted under
# workspace/tmp/workflow-runner/<session>/ and the subagent_id is its basename.
cmd_reconcile() {
  local meta now out="$TMP_POOL/slots.rc" w s st lt ua pd rd dir changed=0 lp rp
  meta="$(meta_path)"
  acquire_lock
  load_slots "$meta"
  now="$(now_utc)"
  : > "$out"
  while IFS="$SEP" read -r w s st lt ua pd rd; do
    if [ "$st" = running ] && [ -z "$rd" ] && valid_id "$s"; then
      dir="$REPO_ROOT/workspace/tmp/workflow-runner/$SESSION_ID/$s"
      lp="$(cat "$dir/lane.pid" 2>/dev/null || true)"
      rp="$(cat "$dir/runner.pid" 2>/dev/null || true)"
      if grep -q 'CONDUCT_EXIT=' "$dir/lane.log" 2>/dev/null \
         && ! pid_alive "$lp" && ! pid_alive "$rp"; then
        st=idle; ua="$now"; changed=1
        printf 'IDLE %s %s\n' "$w" "$(grep 'CONDUCT_EXIT=' "$dir/lane.log" | tail -1)"
      fi
    fi
    printf '%s%s%s%s%s%s%s%s%s%s%s%s%s\n' "$w" "$SEP" "$s" "$SEP" "$st" "$SEP" "$lt" "$SEP" "$ua" \
      "$SEP" "$pd" "$SEP" "$rd" >> "$out"
  done < "$SLOTS"
  mv "$out" "$SLOTS"
  if [ "$changed" -eq 1 ]; then save_slots "$meta"; fi
  release_lock
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
ARG_FORCE=""
ARG_ENVELOPE=""
ARG_PID=""
ARG_RUN_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --envelope)    ARG_ENVELOPE="${2:-}"; shift 2 ;;
    --pid)         ARG_PID="${2:-}"; shift 2 ;;
    --run-dir)     ARG_RUN_DIR="${2:-}"; shift 2 ;;
    --worker-id)   ARG_WORKER="${2:-}"; shift 2 ;;
    --subagent-id) ARG_SUBAGENT="${2:-}"; shift 2 ;;
    --status)      ARG_STATUS="${2:-}"; shift 2 ;;
    --task)        ARG_TASK="$(sanitize_task "${2:-}")"; shift 2 ;;
    --force)       ARG_FORCE=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$SUBCOMMAND" in
  list)    cmd_list ;;
  assign)  cmd_assign "$ARG_WORKER" "$ARG_TASK" "$ARG_ENVELOPE" ;;
  record)  cmd_record "$ARG_WORKER" "$ARG_SUBAGENT" "$ARG_STATUS" "$ARG_TASK" "$ARG_PID" "$ARG_RUN_DIR" ;;
  recycle) cmd_recycle "$ARG_WORKER" "$ARG_FORCE" ;;
  cancel)  cmd_cancel "$ARG_WORKER" ;;
  clear)   cmd_clear ;;
  decisions) cmd_decisions ;;
  reconcile) cmd_reconcile ;;
  *)       usage >&2; exit 1 ;;
esac
