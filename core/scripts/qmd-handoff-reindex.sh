#!/usr/bin/env bash
# qmd-handoff-reindex.sh — single-flight handoff search reindex.
#
# Shared by handoff-finalize.sh and handoff-post.sh so agent ritual
# (finalize-only, ~every 15m) and full developer /handoff (finalize then post)
# cannot double-launch raw qmd writers or race hq-pro's managed timer.
#
# Modes
#   1. Managed (agent boxes): if HQ_QMD_INDEX_USER (default
#      /usr/local/lib/hq-agent/qmd-index-user) is an executable file, invoke it
#      WITHOUT --embed. Lexical refresh uses the one canonical ec2-user lock;
#      the managed timer owns embed cadence. Never call raw
#      qmd cleanup/update/embed when the managed wrapper exists.
#   2. Developer fallback: when the managed wrapper is absent, acquire one
#      nonblocking portable user lock under ${HOME}/.hq/locks/ and run
#      cleanup → update → embed. Busy means quiet success.
#
# Single-flight / dedupe
#   - Portable mkdir lock with an owner record (pid + timestamp + nonce).
#   - Live owners are never stolen; dead owners (and owner-less locks past a
#     short grace window) are reclaimed atomically via rename (nonblocking).
#   - Recent-completion stamp collapses sequential finalize → post into one
#     mutation (default window 90s). Agent ritual (~15m) is well outside the
#     window and still refreshes. Override via QMD_HANDOFF_DEDUPE_SEC (0 disables).
#
# Logging / process discipline
#   - One bounded log (default /tmp/qmd-handoff.log; override via
#     QMD_HANDOFF_LOG, or HANDOFF_LOG_DIR/qmd-handoff.log).
#   - Only the lock winner truncates/writes the log; losers never touch it.
#   - After the winning run, enforce QMD_HANDOFF_LOG_MAX_BYTES (default 65536)
#     by retaining the useful tail (completion evidence).
#   - No unbounded retry loop; failures stay non-blocking (always exit 0).
#   - Managed component stamp owns health on agent boxes.
#
# Env (production defaults; overrides are for tests / rare diagnostics)
#   HQ_QMD_INDEX_USER          managed user-half path
#   QMD_HANDOFF_LOG            full log path
#   HANDOFF_LOG_DIR            log directory when QMD_HANDOFF_LOG unset (default /tmp)
#   QMD_HANDOFF_DEDUPE_SEC     recent-completion skip window seconds (default 90; 0=off)
#   QMD_HANDOFF_LOG_MAX_BYTES  post-run log cap in bytes (default 65536)
#   QMD_HANDOFF_LOCK_GRACE_SEC owner-less lock treated as live for this many
#                              seconds after mkdir (default 5) so reclaim cannot
#                              steal during the owner-write window
#   HOME                       lock root parent (${HOME}/.hq/locks/)
#
# Exit: always 0 (handoff must not block on search reindex).

set -u

# Resolve log path without truncating yet — busy/deduped callers must not wipe
# a winner's evidence.
if [[ -n "${QMD_HANDOFF_LOG:-}" ]]; then
  LOG_PATH="$QMD_HANDOFF_LOG"
else
  LOG_DIR="${HANDOFF_LOG_DIR:-/tmp}"
  LOG_PATH="${LOG_DIR}/qmd-handoff.log"
fi

MANAGED_DEFAULT="/usr/local/lib/hq-agent/qmd-index-user"
MANAGED_BIN="${HQ_QMD_INDEX_USER:-$MANAGED_DEFAULT}"

mode=""
if [[ -n "$MANAGED_BIN" && -x "$MANAGED_BIN" && -f "$MANAGED_BIN" ]]; then
  mode="managed"
elif command -v qmd >/dev/null 2>&1; then
  mode="raw"
else
  # Nothing to do — no managed wrapper and no qmd CLI.
  exit 0
fi

LOCK_ROOT="${HOME:-}/.hq/locks"
if [[ -z "${HOME:-}" ]]; then
  # No HOME → cannot take a user lock safely; skip rather than race.
  exit 0
fi
mkdir -p "$LOCK_ROOT" 2>/dev/null || true
LOCK_DIR="${LOCK_ROOT}/qmd-handoff-reindex.lock"
OWNER_FILE="${LOCK_DIR}/owner"
COMPLETE_STAMP="${LOCK_ROOT}/qmd-handoff-reindex.completed"
DEDUPE_SEC="${QMD_HANDOFF_DEDUPE_SEC:-90}"
LOG_MAX_BYTES="${QMD_HANDOFF_LOG_MAX_BYTES:-65536}"
LOCK_GRACE_SEC="${QMD_HANDOFF_LOCK_GRACE_SEC:-5}"

now_epoch() {
  date +%s 2>/dev/null || echo 0
}

lock_mtime() {
  # Portable-ish mtime; fail soft → 0.
  if stat -c %Y "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  if stat -f %m "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  echo 0
}

# Quiet skip when a recent successful flight already finished. Collapses
# sequential finalize → post without sleeping; ritual cadence (~15m) still runs.
recently_completed() {
  local last now
  # Non-numeric / empty / zero window → never dedupe.
  case "${DEDUPE_SEC}" in
    ''|*[!0-9]*) return 1 ;;
    0) return 1 ;;
  esac
  [[ -f "$COMPLETE_STAMP" ]] || return 1
  last="$(awk -F= '/^ts=/{print $2; exit}' "$COMPLETE_STAMP" 2>/dev/null || true)"
  case "${last}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  now="$(now_epoch)"
  [[ "$now" -ge "$last" ]] 2>/dev/null || return 1
  [[ $((now - last)) -lt "$DEDUPE_SEC" ]] 2>/dev/null
}

write_completion_stamp() {
  {
    echo "ts=$(now_epoch)"
    echo "pid=$$"
    echo "mode=${mode}"
  } >"$COMPLETE_STAMP" 2>/dev/null || true
}

write_owner_record() {
  {
    echo "pid=$$"
    echo "ts=$(now_epoch)"
    echo "nonce=$$.$RANDOM"
  } >"$OWNER_FILE" 2>/dev/null || true
}

# True when we must not steal: live PID owner, or owner-less lock still inside
# the post-mkdir grace window (owner write in progress).
owner_is_live() {
  local opid mt now age grace
  [[ -d "$LOCK_DIR" ]] || return 1

  if [[ -f "$OWNER_FILE" ]]; then
    opid="$(awk -F= '/^pid=/{print $2; exit}' "$OWNER_FILE" 2>/dev/null || true)"
    case "${opid}" in
      ''|*[!0-9]*) ;;
      *)
        # Same-user liveness probe; never treat a live PID as reclaimable.
        if kill -0 "$opid" 2>/dev/null; then
          return 0
        fi
        # Owner record present but process is dead → reclaimable.
        return 1
        ;;
    esac
  fi

  # No usable owner record: only reclaim once past grace (covers mkdir→write
  # window and legacy empty lock dirs after SIGKILL).
  grace="${LOCK_GRACE_SEC}"
  case "${grace}" in
    ''|*[!0-9]*) grace=5 ;;
  esac
  mt="$(lock_mtime)"
  case "${mt}" in
    ''|*[!0-9]*) return 0 ;; # unknown age → conservative: treat as live
  esac
  now="$(now_epoch)"
  age=$((now - mt))
  [[ "$age" -lt 0 ]] && age=0
  [[ "$age" -lt "$grace" ]]
}

release_lock() {
  # Only remove the lock if we still own it (avoid clobbering a reclaimer).
  local opid
  if [[ -f "$OWNER_FILE" ]]; then
    opid="$(awk -F= '/^pid=/{print $2; exit}' "$OWNER_FILE" 2>/dev/null || true)"
    if [[ "$opid" == "$$" ]]; then
      rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
  fi
}

# Enforce modest byte cap after the winning run. Losers never call this.
cap_log() {
  local size max tmp keep
  max="${LOG_MAX_BYTES}"
  case "${max}" in
    ''|*[!0-9]*) return 0 ;;
    0) return 0 ;;
  esac
  [[ -f "$LOG_PATH" ]] || return 0
  size="$(wc -c <"$LOG_PATH" 2>/dev/null | tr -d '[:space:]' || echo 0)"
  case "${size}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [[ "$size" -gt "$max" ]] 2>/dev/null || return 0
  # Retain the useful tail (done/completion lines are written last).
  keep="$max"
  tmp="${LOG_PATH}.cap.$$"
  if tail -c "$keep" "$LOG_PATH" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$LOG_PATH" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# Atomic nonblocking acquire via mkdir. On contention: quiet success for live
# owners; reclaim only when the owner is definitely dead or past grace.
try_acquire_lock() {
  local steal

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    write_owner_record
    return 0
  fi

  # Contended. Never delete a live owner's lock.
  if owner_is_live; then
    return 1
  fi

  # Dead / stale owner (or empty lock past grace): atomic steal.
  # rename is the single-winner primitive; only the stealer who moves the dir
  # proceeds to recreate it.
  steal="${LOCK_DIR}.stale.$$.$RANDOM"
  rm -rf "$steal" 2>/dev/null || true
  if mv "$LOCK_DIR" "$steal" 2>/dev/null; then
    rm -rf "$steal" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      write_owner_record
      return 0
    fi
  fi
  return 1
}

if recently_completed; then
  # Sequential finalize → post (or other rapid double schedule): one mutation.
  exit 0
fi

if ! try_acquire_lock; then
  # Live owner still flying, or lost reclaim race. Quiet success; do not
  # touch the shared log.
  exit 0
fi

trap release_lock EXIT INT TERM HUP

# Re-check stamp after lock: covers a tiny gap where another flight finished
# and released just before we acquired.
if recently_completed; then
  exit 0
fi

# Winner only: truncate log and record this flight.
mkdir -p "$(dirname "$LOG_PATH")" 2>/dev/null || true
{
  echo "qmd-handoff-reindex start mode=${mode} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown) pid=$$"
} >"$LOG_PATH" 2>/dev/null || true

if [[ "$mode" == "managed" ]]; then
  # Lexical-only: do not pass --embed. Managed timer owns embed cadence.
  if ! "$MANAGED_BIN" >>"$LOG_PATH" 2>&1; then
    echo "qmd-handoff-reindex: managed user-half failed (non-blocking)" >>"$LOG_PATH" 2>/dev/null || true
  fi
  echo "qmd-handoff-reindex done mode=managed" >>"$LOG_PATH" 2>/dev/null || true
  write_completion_stamp
  cap_log
  exit 0
fi

# Developer fallback: one raw cleanup → update → embed pipeline.
# Preserve original short-circuit: embed only runs when update succeeds.
{
  qmd cleanup 2>/dev/null || true
  if qmd update 2>/dev/null; then
    qmd embed 2>/dev/null || true
  fi
  echo "qmd-handoff-reindex done mode=raw"
} >>"$LOG_PATH" 2>&1 || true

write_completion_stamp
cap_log
exit 0
