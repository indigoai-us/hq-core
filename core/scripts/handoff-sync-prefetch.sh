#!/bin/bash
# handoff-sync-prefetch.sh - pull the latest session continuity pointer before
# a fresh session reads it.
#
# `/startwork` and `/resumework` both read `workspace/threads/handoff.json`
# (and the thread file it references) to decide what to resume. On a second
# device those files only exist after a vault pull has landed, so a naive
# resume right after sign-in sees stale state. This helper runs that pull
# BEFORE the skill reads the pointer.
#
# Fail-soft:
#   - no-op when the `hq` CLI is missing
#   - no-op when offline or not logged in
#   - timeboxed (default 25s)
#   - never fails the caller: a successful or failed pull are both exit 0;
#     the caller falls through to the local pointer either way.
#
# Usage:
#   handoff-sync-prefetch.sh [--hq-root PATH] [--timeout SECONDS] [--log PATH]
#
# Prints one line of status on stdout for the caller to echo (or ignore):
#   `ok`           - pull completed within the timeout
#   `missing-cli`  - `hq` is not on PATH; nothing was attempted
#   `skipped`      - CLI is present but the pull refused to start (no login,
#                    locked, etc.); local pointer is still used
#   `timed-out`    - pull exceeded the timeout and was killed
#   `error:<rc>`   - pull returned a non-zero exit code
#
# Exits 0 in every case so a shell `|| true` is unnecessary at call sites.

set -euo pipefail

HQ_ROOT=""
TIMEOUT="${HQ_HANDOFF_PREFETCH_TIMEOUT:-25}"
LOG="/tmp/handoff-sync-prefetch.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hq-root) HQ_ROOT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "handoff-sync-prefetch: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! command -v hq >/dev/null 2>&1; then
  echo "missing-cli"
  exit 0
fi

if [[ -z "$HQ_ROOT" ]]; then
  HQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: >>"$LOG"
printf '\n--- handoff-sync-prefetch %s hq_root=%s timeout=%ss ---\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HQ_ROOT" "$TIMEOUT" >>"$LOG"

# Portable timeout: do not depend on coreutils `timeout` (missing on stock
# macOS, missing in some Git Bash installs). Run the child in the background,
# start a watchdog that polls until the deadline, and kill the child on expiry.
# Exit code 124 is reserved to mean "timed out" so the caller branch is
# reachable regardless of which path ran.
run_with_timeout() {
  local secs="$1"; shift
  local flag="/tmp/handoff-sync-prefetch.timeout.$$.$RANDOM"
  rm -f "$flag"
  "$@" >>"$LOG" 2>&1 &
  local child=$!
  (
    local waited=0
    while [ "$waited" -lt "$secs" ]; do
      sleep 1
      kill -0 "$child" 2>/dev/null || exit 0
      waited=$((waited + 1))
    done
    : >"$flag"
    kill -TERM "$child" 2>/dev/null || true
    sleep 1
    if kill -0 "$child" 2>/dev/null; then
      kill -KILL "$child" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  local watchdog=$!
  local rc=0
  wait "$child" 2>/dev/null || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  if [ -f "$flag" ]; then
    rm -f "$flag"
    return 124
  fi
  rm -f "$flag"
  return "$rc"
}

rc=0
run_with_timeout "$TIMEOUT" \
  hq sync pull --personal --hq-root "$HQ_ROOT" --lock-timeout 0 \
  || rc=$?
printf 'exit=%s\n' "$rc" >>"$LOG"

case "$rc" in
  0)   echo "ok" ;;
  124) echo "timed-out" ;;
  *)
    # Distinguish "could not even start" (no login / lock refused) from a real
    # error so operator logs don't scream when the user simply isn't signed in
    # yet. `hq sync pull` returns 1 for both; the log file carries the detail.
    if grep -qE 'not logged in|no cached session|refused immediately|requires login' "$LOG" 2>/dev/null; then
      echo "skipped"
    else
      echo "error:${rc}"
    fi
    ;;
esac
exit 0
