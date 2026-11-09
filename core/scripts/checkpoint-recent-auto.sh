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
# Usage: checkpoint-recent-auto.sh [hq_root] [minutes] [session_id]
# Exit 0 always (fail-soft); prints at most one path.
#
# When session_id is set (arg 3 or HQ_CHECKPOINT_SESSION_ID), only a file
# whose JSON session_id matches is returned. That stops /checkpoint from
# upgrading another session's auto-checkpoint. No match prints nothing.

set -uo pipefail

root="${1:-${HQ_ROOT:-$PWD}}"
minutes="${2:-5}"
session="${3:-${HQ_CHECKPOINT_SESSION_ID:-}}"
limit="${HQ_CHECKPOINT_FIND_TIMEOUT:-10}"

case "$minutes" in ''|*[!0-9]*) minutes=5 ;; esac
case "$limit" in ''|*[!0-9]*) limit=10 ;; esac
case "$session" in
  ''|*[!A-Za-z0-9._-]*) session="" ;;
esac

threads="$root/workspace/threads"
[ -d "$threads" ] || exit 0

# hq_perl_spawn restores the caller's locale before exec.
# shellcheck source=lib/perl-child-locale.sh
. "${BASH_SOURCE[0]%/*}/lib/perl-child-locale.sh" 2>/dev/null \
  || hq_perl_spawn() { local p="$1"; shift; LC_ALL=C "${HQ_PERL_BIN:-perl}" -e "$p" "$@"; }

candidates=""
candidates="$(
  hq_perl_spawn 'alarm shift @ARGV; exec @ARGV or exit 127' "$limit" \
    find "$threads" -maxdepth 1 -type f -name 'T-*-auto-*.json' -mmin "-$minutes" -print \
    | LC_ALL=C sort -r
  )" 2>/dev/null || true

[ -n "$candidates" ] || exit 0

if [ -z "$session" ]; then
  printf '%s\n' "$candidates" | head -1
  exit 0
fi

# Fail closed for a named session: never return another session's file,
# and never return a file with no session_id (legacy auto-checkpoints).
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -f "$path" ] || continue
  got="$(jq -r '.session_id // empty' "$path" 2>/dev/null || true)"
  if [ "$got" = "$session" ]; then
    printf '%s\n' "$path"
    exit 0
  fi
done <<< "$candidates"

exit 0
