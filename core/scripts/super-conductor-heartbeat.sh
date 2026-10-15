#!/usr/bin/env bash
# super-conductor-heartbeat.sh — the persistent wake source for /super-conductor.
#
# Run it under `hq monitor start --persistent` so every line it prints is
# delivered into the conductor session, including while the session is idle
# (the async Stop waiter wakes it). This replaces "the owner types sweep all":
# the sweep is due on a fixed cadence whether or not the last turn ended on a
# question, a compact, or an error.
#
# Each loop waits on the conduct link for up to <interval> seconds:
#   - a child report arrives  -> prints a REPORT line at once
#   - the interval elapses    -> prints a TICK line (sweep the channels)
# After a REPORT the next wait is a plain timer, so an undrained mailbox wakes
# the session at most twice per interval instead of spinning.
#
# Usage:
#   super-conductor-heartbeat.sh --interval <seconds> [--link <id>]
#       [--channels <csv>] [--state <save-file>] [--once]
#
# Exit: 0 when the link closes (the conductor is off), 1 after repeated waiter
# errors, 2 on bad arguments.
set -uo pipefail

interval=""
link=""
channels="sessions,hq_dms"
state=""
once=0
HQ_BIN="${HQ_BIN:-hq}"
MAX_ERRORS="${SC_HEARTBEAT_MAX_ERRORS:-5}"
ERROR_BACKOFF="${SC_HEARTBEAT_ERROR_BACKOFF:-30}"
MIN_INTERVAL="${SC_HEARTBEAT_MIN_INTERVAL:-30}"

usage() {
  echo "usage: super-conductor-heartbeat.sh --interval <seconds> [--link <id>] [--channels <csv>] [--state <save-file>] [--once]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) interval="${2:-}"; shift 2 ;;
    --link) link="${2:-}"; shift 2 ;;
    --channels) channels="${2:-}"; shift 2 ;;
    --state) state="${2:-}"; shift 2 ;;
    --once) once=1; shift ;;
    -h|--help) usage ;;
    *) echo "super-conductor-heartbeat: unknown argument $1" >&2; usage ;;
  esac
done

if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
  echo "super-conductor-heartbeat: --interval must be whole seconds" >&2
  exit 2
fi
# Same clamp as the skill's watch_interval rule.
(( interval < MIN_INTERVAL )) && interval=$MIN_INTERVAL
(( interval > 3600 )) && interval=3600

resume_hint="Run the /super-conductor wakeup (Step 7)"
[[ -n "$state" ]] && resume_hint="Read $state, then run the /super-conductor wakeup (Step 7)"

emit() { # kind detail
  printf 'SUPER-CONDUCTOR %s %s | channels: %s | %s.\n' \
    "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$channels" "$2"
}

errors=0
timer_next=0
while :; do
  if [[ -z "$link" || "$timer_next" -eq 1 ]]; then
    sleep "$interval"
    timer_next=0
    emit TICK "Sweep due. $resume_hint"
  else
    out="$("$HQ_BIN" lanes link wait --link "$link" --timeout "$interval" 2>&1)"
    rc=$?
    case "$rc" in
      0)
        errors=0
        timer_next=1
        emit REPORT "A conducted session reported. Drain the link, then sweep. $resume_hint"
        ;;
      3)
        errors=0
        emit TICK "Sweep due. $resume_hint"
        ;;
      *)
        if grep -qiE 'link_not_found|link_closed|no such link' <<<"$out"; then
          emit LINK-CLOSED "The conduct link is gone; the heartbeat is stopping. Confirm the conductor is off or reopen the link"
          exit 0
        fi
        errors=$((errors + 1))
        first_line="$(head -n1 <<<"$out")"
        emit WAITER-ERROR "Link wait failed (exit $rc, attempt $errors/$MAX_ERRORS): ${first_line:0:160}. Sweep anyway. $resume_hint"
        if (( errors >= MAX_ERRORS )); then
          emit STOPPED "Heartbeat gave up after $MAX_ERRORS waiter errors. Re-arm it per Step 2b"
          exit 1
        fi
        sleep "$ERROR_BACKOFF"
        ;;
    esac
  fi
  [[ "$once" -eq 1 ]] && exit 0
done
