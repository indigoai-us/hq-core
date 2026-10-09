#!/usr/bin/env bash
# hq-core: public
# conduct-lane-wait.sh — the background waiter for one /conduct lane, as
# .claude/skills/_shared/lane-dispatch-protocol.md §5 describes it. Run it as a
# background call right after conduct-lane-launch.sh start; the harness wakes
# the conductor when it exits.
#
# Usage:
#   bash core/scripts/conduct-lane-wait.sh --run-dir <dir> [--interval <secs>]
#
#   --run-dir <dir>     the lane's run dir (relative to the HQ root, or absolute)
#   --interval <secs>   poll interval (default 10)
#   --grace <secs>      how long a deadline stop waits for the runner's own
#                       shutdown before force (default 30; protocol §5)
#
# Reads deadline, worker_id and session_id from the run dir (the launcher
# writes them). Refuses to run without a deadline: an unbounded wait is the
# failure the deadline file exists to prevent.
#
# Prints `outcome=<exited|died|never-started|deadline> engine_gone=<yes|no>
# lane=<run id>`, then the last 30 lines of lane.log.
#
# Exit codes: 0 exited and engine gone, 1 usage error, 10 died,
# 11 never-started, 12 deadline (stopped), 13 an engine process survived
# (the slot stays running; a human decides).

set -euo pipefail

ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

usage() { sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "conduct-lane-wait: $*" >&2; exit 1; }

D=""
INTERVAL=10
GRACE=30
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) [ -n "${2:-}" ] || die "--run-dir needs a value"; D="$2"; shift 2 ;;
    --interval) [ -n "${2:-}" ] || die "--interval needs a value"; INTERVAL="$2"; shift 2 ;;
    --grace) [ -n "${2:-}" ] || die "--grace needs a value"; GRACE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[ -n "$D" ] || die "--run-dir is required"
case "$INTERVAL" in ''|*[!0-9]*|0) die "--interval must be a positive integer" ;; esac
case "$GRACE" in ''|*[!0-9]*) die "--grace must be a non-negative integer" ;; esac
case "$D" in /*) ;; *) D="$ROOT/${D#./}" ;; esac
D="${D%/}"
[ -d "$D" ] || die "run dir does not exist: $D"

L="$D/lane.log"
P="$D/lane.pid"
deadline="$(cat "$D/deadline" 2>/dev/null || true)"
[ -n "$deadline" ] || die "no deadline file in $D; refusing to wait unbounded"
case "$deadline" in *[!0-9]*) die "deadline file is not an epoch: $deadline" ;; esac
worker="$(cat "$D/worker_id" 2>/dev/null || true)"
owner="$(cat "$D/session_id" 2>/dev/null || true)"
run_id="$(basename "$D")"

record() {
  [ -n "$worker" ] || return 0
  if [ -n "$owner" ]; then
    bash "$ROOT/core/scripts/conduct-pool.sh" --session-id "$owner" record --worker-id "$worker" \
      --subagent-id "$run_id" --status "$1" >/dev/null 2>&1 || true
  else
    bash "$ROOT/core/scripts/conduct-pool.sh" record --worker-id "$worker" \
      --subagent-id "$run_id" --status "$1" >/dev/null 2>&1 || true
  fi
}

marker() { grep -q 'CONDUCT_EXIT=' "$L" 2>/dev/null; }

starts=0
outcome=exited
until marker; do
  if [ "$(date +%s)" -ge "$deadline" ]; then outcome=deadline; break; fi
  if [ -s "$P" ]; then
    # The wrapper's own group, not the engine's (the runner spawns the engine
    # detached). An empty group with no marker means the lane died.
    pgrep -g "$(cat "$P")" >/dev/null 2>&1 || { marker || outcome=died; break; }
  else
    starts=$((starts + 1))
    [ "$starts" -gt 6 ] && { outcome=never-started; break; }
  fi
  sleep "$INTERVAL"
done

graceful_attempted=no
if [ "$outcome" = deadline ]; then
  # Ask the runner to stop; it is the only process that holds the engine's group.
  rpid="$(cat "$D/runner.pid" 2>/dev/null || true)"
  [ -n "$rpid" ] && kill -TERM "$rpid" 2>/dev/null || true
  stopped=no
  i=0
  while [ "$i" -lt "$GRACE" ]; do
    marker && { stopped=yes; break; }
    sleep 1; i=$((i + 1))
  done
  marker && stopped=yes
  if [ "$stopped" = no ] && [ -s "$P" ]; then
    kill -KILL -- -"$(cat "$P")" 2>/dev/null || true
    echo "WARNING: the runner never acknowledged the stop. Do NOT recycle this slot."
  fi
  graceful_attempted=yes
fi

if [ "$outcome" = exited ]; then
  record idle
fi

# Confirm the engine group last, on every outcome (protocol §5).
engine_gone=yes
epgid=""
if [ -f "$D/journal.jsonl" ]; then
  epgid="$(jq -r 'select(.event=="agent-spawned")|.pgid' "$D/journal.jsonl" 2>/dev/null | tail -1 || true)"
fi
case "$epgid" in ''|null|*[!0-9]*) epgid="" ;; esac
if [ -n "$epgid" ] && pgrep -g "$epgid" >/dev/null 2>&1; then
  if [ "$graceful_attempted" = yes ]; then
    kill -KILL -- -"$epgid" 2>/dev/null || true
    sleep 2
  fi
  pgrep -g "$epgid" >/dev/null 2>&1 && engine_gone=no
fi
if [ "$engine_gone" = no ]; then
  record running
fi

echo "outcome=$outcome engine_gone=$engine_gone lane=$run_id"
tail -30 "$L" 2>/dev/null || true

[ "$engine_gone" = no ] && exit 13
case "$outcome" in
  exited) exit 0 ;;
  died) exit 10 ;;
  never-started) exit 11 ;;
  deadline) exit 12 ;;
esac
