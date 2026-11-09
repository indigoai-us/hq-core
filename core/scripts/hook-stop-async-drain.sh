#!/usr/bin/env bash
# hq-core: public
# Single-flight drain for lib/hook-stop-async.sh. The enqueuer created
# queue/drain.lock with pid 0; this worker writes its own pid into it at once
# and refreshes it before every item, so a crashed or never-started worker
# leaves a lock the next enqueue can recognise as stale and take over.
# Usage: hook-stop-async-drain.sh <queue-dir>

set -uo pipefail

QUEUE="${1:-}"
[ -n "$QUEUE" ] || exit 0
SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
# shellcheck source=core/scripts/lib/hook-stop-async.sh
. "$SCRIPT_DIR/lib/hook-stop-async.sh"

ITEMS="$QUEUE/items"
LOCK="$QUEUE/drain.lock"
mkdir -p "$ITEMS" 2>/dev/null || true

lock_pid() {
  local pid="" _at
  read -r pid _at <"$LOCK" 2>/dev/null || return 1
  printf '%s' "$pid"
}

lock_is_mine() { [ "$(lock_pid)" = "$$" ]; }

# Refresh the lock, but only while this worker still owns it. A worker that
# was judged hung and replaced stops instead of taking the lock back.
refresh_lock() {
  lock_is_mine || exit 0
  printf '%s %s\n' "$$" "$(hook_stop_async_now)" >"$LOCK" 2>/dev/null || true
}

# Start: the enqueuer left pid 0, or this pid after an exec. Anything else
# means another worker owns the queue.
case "$(lock_pid)" in
  0|"$$") printf '%s %s\n' "$$" "$(hook_stop_async_now)" >"$LOCK" 2>/dev/null || exit 0 ;;
  *) exit 0 ;;
esac

# Keep the log bounded: rotate at about 1 MB, one old copy.
LOG_MAX="${HQ_HOOK_ASYNC_LOG_MAX_BYTES:-1048576}"
if [ -f "$QUEUE/drain.log" ] && [ "$(wc -c <"$QUEUE/drain.log" 2>/dev/null | tr -d ' ')" -gt "$LOG_MAX" ] 2>/dev/null; then
  mv -f "$QUEUE/drain.log" "$QUEUE/drain.log.1" 2>/dev/null || true
fi
# The worker owns its log. It is started with no output redirect (see
# lib/hook-stop-async.sh), so this is the only handle on the file.
exec >>"$QUEUE/drain.log" 2>&1

# Items a killed worker left claimed (<id>.running.<pid>, pid dead) go back
# to the queue, up to MAX_ATTEMPTS runs; then they are dropped with a log line.
MAX_ATTEMPTS="${HQ_HOOK_ASYNC_MAX_ATTEMPTS:-3}"
for running in "$ITEMS"/*.running.*; do
  [ -d "$running" ] || continue
  owner="${running##*.running.}"
  [ "$owner" = "$$" ] && continue
  case "$owner" in ''|*[!0-9]*) ;; *) kill -0 "$owner" 2>/dev/null && continue ;; esac
  attempts="$(cat "$running/attempts" 2>/dev/null || echo 0)"
  case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
  attempts=$((attempts + 1))
  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    printf '%s hook-stop-async: dropped %s after %s attempts (script %s)\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "${running##*/}" "$attempts" \
      "$(cat "$running/script" 2>/dev/null)" >>"$QUEUE/drain.log" 2>/dev/null
    rm -rf "$running"
    continue
  fi
  printf '%s\n' "$attempts" >"$running/attempts" 2>/dev/null || true
  mv "$running" "${running%.running.*}" 2>/dev/null || true
done

release_lock() {
  lock_is_mine && rm -f "$LOCK" 2>/dev/null
  return 0
}

run_one() {
  local item="$1" running="$1.running.$$"
  # Claim by rename: a second worker after a takeover cannot run it too.
  if ! mv "$item" "$running" 2>/dev/null; then
    CLAIM_FAILED=1
    printf '%s hook-stop-async: cannot claim %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "${item##*/}"
    return 1
  fi
  local script cwd
  script="$(cat "$running/script" 2>/dev/null || true)"
  cwd="$(cat "$running/cwd" 2>/dev/null || true)"
  # The worker's own directory belongs to whichever session started it, so an
  # item whose directory is gone is skipped rather than run there.
  if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
    printf '%s hook-stop-async: skipped %s, cwd is gone: %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "${running##*/}" "$cwd"
  elif [ -n "$script" ] && [ -f "$script" ]; then
    (
      # The worker's environment belongs to whichever session started it.
      # Clear it, then load only what this item recorded. PATH stays until the
      # item sets its own, so an item without an env file can still find bash.
      for _name in $(compgen -e); do
        [ "$_name" = PATH ] || unset "$_name" 2>/dev/null
      done
      if [ -f "$running/env.sh" ]; then
        set -a
        . "$running/env.sh"
        set +a
      fi
      export HQ_HOOK_ASYNC_DRAIN=1
      cd "$cwd" || exit 0
      bash "$script" <"$running/stdin"
    ) || true
  fi
  rm -rf "$running"
}

# Set when an item could not be claimed. It stays in the queue for a later
# worker; this one must not loop on it or keep the lock fresh forever.
CLAIM_FAILED=0
while true; do
  found=0
  for item in "$ITEMS"/*; do
    [ -d "$item" ] || continue
    case "$item" in *.running.*) continue ;; esac
    refresh_lock
    run_one "$item" && found=1
  done
  [ "$found" = "1" ] || break
done

release_lock
[ "$CLAIM_FAILED" = "0" ] || exit 0

# An enqueue that lost the lock race may have landed after the last scan.
for item in "$ITEMS"/*; do
  [ -d "$item" ] || continue
  case "$item" in *.running.*) continue ;; esac
  if hook_stop_async_lock_take "$LOCK" "$$"; then
    exec bash "$SELF" "$QUEUE"
  fi
  break
done
exit 0
