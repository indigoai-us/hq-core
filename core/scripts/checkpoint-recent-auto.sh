#!/usr/bin/env bash
# checkpoint-recent-auto.sh — print the newest auto-checkpoint thread written
# in the last N minutes (default 5), or nothing.
#
# Used by /checkpoint step 1. It replaces an inline
# `find workspace/threads -name ...` that had no depth bound. Auto-checkpoints
# live only at the top level of workspace/threads, so the search is
# -maxdepth 1, and it never touches the rest of workspace/ (workspace/worktrees
# holds full repo checkouts — scanning it took minutes on a large HQ).
#
# The search runs in the foreground with no background child, and a perl
# alarm bounds it: the alarm survives exec, so find itself receives SIGALRM
# after HQ_CHECKPOINT_FIND_TIMEOUT seconds (default 10). If the caller's shell
# is killed, find dies by the same deadline instead of running on as an orphan.
#
# Usage: checkpoint-recent-auto.sh [hq_root] [minutes]
# Exit 0 always (fail-soft); prints at most one path.

set -uo pipefail

root="${1:-${HQ_ROOT:-$PWD}}"
minutes="${2:-5}"
limit="${HQ_CHECKPOINT_FIND_TIMEOUT:-10}"

case "$minutes" in ''|*[!0-9]*) minutes=5 ;; esac
case "$limit" in ''|*[!0-9]*) limit=10 ;; esac

threads="$root/workspace/threads"
[ -d "$threads" ] || exit 0

{
  perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$limit" \
    find "$threads" -maxdepth 1 -type f -name 'T-*-auto-*.json' -mmin "-$minutes" -print \
    | LC_ALL=C sort -r | head -1
} 2>/dev/null

exit 0
