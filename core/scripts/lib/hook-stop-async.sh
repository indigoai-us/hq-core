# hq-core: public
# Source from a Stop hook. When the master hook is dispatching and async is
# on, copy stdin into a queue item and return to the turn. A single detached
# worker runs the same script with HQ_HOOK_ASYNC_DRAIN=1.
#
#   hook_stop_async_enter "$0" || true
#   # inline body follows; enter exit 0s the hook when it queued the work
#
# HQ_HOOK_ASYNC=0 forces the inline body (measurements and unit tests).
# HQ_HOOK_ASYNC_DRAIN=1 is set by the worker and means "run the body".
# Direct invocation (no HQ_HOOK_EVENT) stays inline so existing tests keep
# their stdout and side effects. Only hooks whose output is not turn context
# and that never emit a block decision may use this.
#
# Lock: $queue/drain.lock is a file holding "<pid> <epoch-seconds>". It is
# created in one O_EXCL write (noclobber) with pid 0, meaning "launching".
# The worker rewrites it with its own pid and refreshes the time before each
# item. A lock is stale, and is taken over, when its pid is 0, missing or
# dead and it is older than HQ_HOOK_ASYNC_LAUNCH_GRACE seconds (default 10),
# or when it has not been refreshed for HQ_HOOK_ASYNC_LOCK_MAX_AGE seconds
# (default 1800, a hung item). Workers claim each item by renaming it, so two
# workers after a takeover never run the same item twice.

hook_stop_async_now() { date +%s 2>/dev/null || echo 0; }

# Exit 0 when the lock at $1 is stale (or unreadable), 1 when it is live.
hook_stop_async_lock_stale() {
  local lock="$1" pid="" at="" now age grace max_age
  [ -f "$lock" ] || return 1
  read -r pid at <"$lock" 2>/dev/null || true
  case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  now="$(hook_stop_async_now)"
  age=$((now - at))
  grace="${HQ_HOOK_ASYNC_LAUNCH_GRACE:-10}"
  max_age="${HQ_HOOK_ASYNC_LOCK_MAX_AGE:-1800}"
  [ "$age" -ge "$max_age" ] && return 0
  if [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  [ "$age" -ge "$grace" ]
}

# Create the lock atomically with "<pid> <now>". Exit 0 when this call won.
hook_stop_async_lock_create() {
  local lock="$1" pid="$2"
  ( set -C; printf '%s %s\n' "$pid" "$(hook_stop_async_now)" >"$lock" ) 2>/dev/null
}

# Take the lock: create it, or replace a stale one. Exit 0 when held.
hook_stop_async_lock_take() {
  local lock="$1" pid="$2" stale
  # A directory lock is the pre-release format; it never held a usable pid.
  [ -d "$lock" ] && rm -rf "$lock" 2>/dev/null
  hook_stop_async_lock_create "$lock" "$pid" && return 0
  hook_stop_async_lock_stale "$lock" || return 1
  # Rename first: only one contender's rename of the stale file succeeds.
  stale="$lock.stale.$$.${RANDOM:-0}"
  mv -f "$lock" "$stale" 2>/dev/null || return 1
  rm -f "$stale" 2>/dev/null || true
  hook_stop_async_lock_create "$lock" "$pid"
}

hook_stop_async_enter() {
  local script="$1"
  [ "${HQ_HOOK_ASYNC_DRAIN:-}" = "1" ] && return 1
  [ "${HQ_HOOK_ASYNC:-1}" = "0" ] && return 1
  [ -n "${HQ_HOOK_EVENT:-}" ] || return 1

  local input=""
  IFS= read -r -d '' input || true

  local root="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
  if [ -z "$root" ]; then
    root="$(cd "$(dirname "$script")/../../.." 2>/dev/null && pwd)" || root=""
  fi
  local queue="${HQ_HOOK_ASYNC_DIR:-${HOME:-/tmp}/.hq/hook-async}"
  local items="$queue/items"
  # Not queued: run the body inline with the payload we already read.
  if ! mkdir -p "$items" 2>/dev/null; then
    printf '%s' "$input" | HQ_HOOK_ASYNC_DRAIN=1 bash "$script"
    exit $?
  fi
  # Items hold the hook payload, which can include conversation text.
  chmod 700 "$queue" "$items" 2>/dev/null || true

  local ts="${EPOCHREALTIME:-}"
  ts="${ts//./}"
  [ -n "$ts" ] || ts="$(date +%s)000000"
  local id="${ts}-$$-${RANDOM:-0}"
  local stage="$queue/staging.$id"
  if ! mkdir "$stage" 2>/dev/null \
    || ! printf '%s' "$input" >"$stage/stdin" \
    || ! printf '%s\n' "$script" >"$stage/script" \
    || ! printf '%s\n' "${PWD:-}" >"$stage/cwd"; then
    rm -rf "$stage" 2>/dev/null || true
    printf '%s' "$input" | HQ_HOOK_ASYNC_DRAIN=1 bash "$script"
    exit $?
  fi

  # The worker runs each item with exactly these variables (see run_one in
  # hook-stop-async-drain.sh). This is an allowlist so tokens stay off disk.
  local envf="$stage/env.sh"
  : >"$envf"
  local key
  for key in \
    PATH HOME USER LOGNAME TMPDIR TMP TEMP \
    CLAUDE_PROJECT_DIR HQ_ROOT HQ_SESSION_ID CLAUDE_CODE_SESSION_ID \
    CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID \
    HQ_HARNESS HQ_WORK_MESH_HARNESS HQ_CHECKPOINT_RUNTIME \
    HQ_ADAPTER_CONTRACT_VERSION WORK_MESH_SEQ_DIR \
    HQ_DISABLED_HOOKS HQ_WORK_MESH_DISABLED \
    HQ_CLI_BIN HQ_OFFLOAD_MIN_BYTES \
    HQ_AUTOCOMMIT HQ_AUTOCOMMIT_STRICT HQ_AUTOCOMMIT_LOG_MAX_BYTES \
    HQ_AUTOCOMMIT_LOCK_PROBE HQ_AUTOCOMMIT_PRESTAGED_STALE_MINUTES \
    HQ_AUTOCOMMIT_STALE_LOCK_MINUTES HQ_COMPANY_UID HQ_COMPANY_SLUG HQ_FLAGS_API_URL \
    WORK_MESH_SPOOL LANG LC_ALL LC_CTYPE SHELL XDG_CONFIG_HOME XDG_CACHE_HOME \
    SYSTEMROOT SystemRoot WINDIR COMSPEC PATHEXT APPDATA LOCALAPPDATA \
    USERPROFILE HOMEDRIVE HOMEPATH PROGRAMDATA PROGRAMFILES MSYSTEM MSYS
  do
    if [ -n "${!key+x}" ]; then
      printf '%s=%q\n' "$key" "${!key}" >>"$envf"
    fi
  done
  # Publish the item only once it is complete, so a worker never reads half.
  if ! mv "$stage" "$items/$id" 2>/dev/null; then
    rm -rf "$stage"
    printf '%s' "$input" | HQ_HOOK_ASYNC_DRAIN=1 bash "$script"
    exit $?
  fi

  local runner="$root/core/scripts/hook-stop-async-drain.sh"
  [ -f "$runner" ] || runner="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-stop-async-drain.sh"
  local hidden="$root/core/scripts/hq-hidden-run.sh"
  [ -f "$hidden" ] || hidden="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hq-hidden-run.sh"
  local lock="$queue/drain.lock"
  if hook_stop_async_lock_take "$lock" 0; then
    # If the hidden launcher refuses (for example a path cmd.exe cannot
    # quote), a plain detach still drains the queue; a console is better
    # than a queue that never runs.
    # No --logfile: the worker opens drain.log itself. On Windows a cmd.exe
    # redirect would hold the file without write sharing, and the worker's
    # own appends would fail with "Device or resource busy".
    if ! bash "$hidden" -- bash "$runner" "$queue" 2>>"$queue/drain.log" \
      && ! bash "${hidden%/*}/hq-detach.sh" -- bash "$runner" "$queue" 2>>"$queue/drain.log"; then
      # Nothing could start in the background, so the turn pays for the work:
      # drain here, under the launching lock this call already holds.
      printf '%s hook-stop-async: launch failed, draining inline\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" >>"$queue/drain.log" 2>/dev/null || true
      bash "$runner" "$queue" </dev/null >/dev/null 2>&1 || true
      # The worker could not run (or lost the lock): run this hook's own item.
      if [ -d "$items/$id" ] && mv "$items/$id" "$items/$id.running.$$" 2>/dev/null; then
        printf '%s' "$input" | HQ_HOOK_ASYNC_DRAIN=1 bash "$script" >>"$queue/drain.log" 2>&1 || true
        rm -rf "$items/$id.running.$$" 2>/dev/null || true
      fi
      local holder="" _at=""
      read -r holder _at <"$lock" 2>/dev/null || true
      [ "$holder" != "0" ] || rm -f "$lock" 2>/dev/null || true
    fi
  fi
  exit 0
}
