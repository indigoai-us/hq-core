#!/usr/bin/env bash
# hq-core: public
# SessionStart: sweep away conduct lanes whose owning session is gone.
#
# Detached lanes are started so they survive the turn that launched them, which
# is correct — a lane has to outlive its turn. Nothing existed on the other
# side of that, though, so a lane whose owner exited kept running unsupervised,
# each one fanning out a full test suite. They accumulated across days until
# the machine was oversubscribed and every app on it went sluggish.
#
# Session start is the natural moment to sweep: a session opening is the best
# available signal that an earlier one ended. The sweep never touches a lane
# whose owning session is still alive, at any age — see conduct-reap.sh.
set -uo pipefail

case ",${HQ_DISABLED_HOOKS:-}," in *,conduct-reap,*|*,\*,*) exit 0 ;; esac

HOOK_FILE="${BASH_SOURCE[0]}"
if [ -z "${HQ_ROOT:-}" ]; then
  HQ_ROOT="$(cd "${HOOK_FILE%/*}/../../.." 2>/dev/null && pwd)" || exit 0
fi
REAP="$HQ_ROOT/core/scripts/conduct-reap.sh"
[ -x "$REAP" ] || [ -f "$REAP" ] || exit 0

STATE_DIR="$HQ_ROOT/workspace/tmp/conduct-reap"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
LOG="$STATE_DIR/sweep.log"

# Single-flight. `mkdir` is the atomic primitive here: opening several sessions
# at once must not start several sweeps racing to signal the same pids.
LOCK="$STATE_DIR/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # A lock older than an hour outlived any real sweep; take it over.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi

# Don't re-sweep on every session opened in a burst.
STAMP="$STATE_DIR/.last-sweep"
if [ -f "$STAMP" ] && [ -z "$(find "$STAMP" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
  rmdir "$LOCK" 2>/dev/null
  exit 0
fi

# Detached, so session start never waits on it. The age gate is deliberately
# generous: the ownership check is what makes this safe, and the gate is only
# there so a lane launched seconds ago by a session still finding its feet is
# never a candidate.
(
  {
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') sweep ==="
    bash "$REAP" --apply --kill --min-age "${HQ_CONDUCT_REAP_MIN_AGE:-120}" 2>&1
  } >> "$LOG" 2>&1
  touch "$STAMP" 2>/dev/null
  rmdir "$LOCK" 2>/dev/null
  # Keep the log from growing without bound.
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -500 "$LOG" > "$LOG.trim" 2>/dev/null && mv "$LOG.trim" "$LOG" 2>/dev/null
  fi
) >/dev/null 2>&1 &

exit 0
