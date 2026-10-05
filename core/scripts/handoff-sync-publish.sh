#!/bin/bash
# handoff-sync-publish.sh - push the session continuity pointer to the personal vault.
#
# Cross-device handoff depends on `workspace/threads/handoff.json` and the
# single thread file it points to reaching the vault before a fresh session on
# another machine runs `/startwork` or `/resumework`. The workspace tree is
# otherwise machine-local (`PERSONAL_VAULT_EXCLUDED_TOP_LEVEL`), so without a
# push run between the two sessions machine B sees stale state or no handoff
# at all. See hq-cloud-sync `computeContinuityPointerPaths`.
#
# This helper is intentionally minimal and fail-soft:
#   - no-op when the `hq` CLI is missing (fresh install, agent box without CLI)
#   - no-op when offline or not logged in (vault push will fail; we never
#     block /handoff on cloud reachability)
#   - timeboxed (default 25s) so a slow network cannot stall session end
#   - detached by default; the handoff-finalize payload is already emitted
#
# Usage:
#   handoff-sync-publish.sh [--hq-root PATH] [--timeout SECONDS]
#                          [--sync] [--log PATH]
#
#   --sync     Run synchronously in the foreground and return the exit code.
#              Default behaviour forks a backgrounded worker and prints its PID.
#   --timeout  Wall-clock bound in seconds; the push is killed on expiry.
#   --log      Append combined stdout/stderr to this path (default: `/tmp/handoff-sync-publish.log`).
#
# Exits 0 on dispatch (background mode) or on push success (sync mode).
# A sync-mode failure returns the underlying `hq` exit, or 124 on timeout.

set -euo pipefail

HQ_ROOT=""
TIMEOUT="${HQ_HANDOFF_PUBLISH_TIMEOUT:-25}"
MODE="background"
LOG="/tmp/handoff-sync-publish.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hq-root) HQ_ROOT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --sync) MODE="sync"; shift ;;
    --log) LOG="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "handoff-sync-publish: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! command -v hq >/dev/null 2>&1; then
  # Fresh install / agent box without the CLI. Nothing to publish from here.
  exit 0
fi

if [[ -z "$HQ_ROOT" ]]; then
  HQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# Portable timeout: do not depend on coreutils `timeout` (missing on stock
# macOS, missing in some Git Bash installs). Return 124 on timeout so the
# caller can distinguish wall-clock expiry from a real `hq` error.
run_with_timeout() {
  local secs="$1"; shift
  local flag="/tmp/handoff-sync-publish.timeout.$$.$RANDOM"
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

run_publish() {
  # `hq sync push --personal` is the canonical publish path for the session
  # continuity pointer (the vault scope that carves out handoff.json + the
  # referenced thread file). A `--lock-timeout 0` keeps the push from queueing
  # behind a long-running sync pass; the operator can rerun later.
  run_with_timeout "$TIMEOUT" \
    hq sync push --personal --hq-root "$HQ_ROOT" --lock-timeout 0 \
      --message "handoff continuity pointer"
}

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: >>"$LOG"
printf '\n--- handoff-sync-publish %s hq_root=%s mode=%s timeout=%ss ---\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HQ_ROOT" "$MODE" "$TIMEOUT" >>"$LOG"

if [[ "$MODE" == "sync" ]]; then
  rc=0; run_publish || rc=$?
  printf 'exit=%s\n' "$rc" >>"$LOG"
  exit "$rc"
fi

# background: detach cleanly so handoff-finalize can return immediately.
(
  rc=0
  run_publish || rc=$?
  printf 'exit=%s\n' "$rc" >>"$LOG"
) </dev/null >>"$LOG" 2>&1 &
disown || true
printf '%s\n' "$!"
exit 0
