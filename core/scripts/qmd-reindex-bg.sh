#!/usr/bin/env bash
# qmd-reindex-bg.sh — single-flight background search reindex for handoff/sync.
#
# Ownership (PR #149 / hq-pro #1790 / US-001):
#   - Hosted agent boxes: NEVER mutate qmd from handoff. Managed timer/indexer
#     owns all update/embed. Print "skipped-agent" so callers can record it.
#   - Laptop / non-agent HQ: one nonblocking single-flight lock around
#     cleanup → update → embed. Never start a second writer when the lock is busy.
#
# Architecture (nonblocking for handoff callers that use command substitution):
#   Launcher (default): hard-skip agents, skip missing qmd, then nohup-spawn
#     this same script with --worker and print the real child PID immediately.
#   Worker (--worker): owns portable lock / dedupe / qmd pipeline; never respawns.
#
# Handoff does NOT invoke managed wrappers (no agent-side freshness ownership).
#
# Usage:
#   core/scripts/qmd-reindex-bg.sh
#   core/scripts/qmd-reindex-bg.sh --log /tmp/qmd-handoff.log
#   core/scripts/qmd-reindex-bg.sh --worker --log /tmp/qmd-handoff.log   # internal
#
# Stdout tokens (launcher only):
#   skipped-agent  — agent box (or forced skip); no qmd invoked
#   skipped        — qmd CLI missing; no work started
#   <pid>          — real detached --worker child PID
#
# Exit 0 always for callers that must not fail handoff.

set -u

# Absolute self path for reliable nohup re-exec (caller may have relative $0).
_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
  /*) ;;
  *) _SELF="$(cd "$(dirname "$_SELF")" && pwd)/$(basename "$_SELF")" ;;
esac

LOG="${QMD_REINDEX_LOG:-${QMD_HANDOFF_LOG:-${HANDOFF_LOG_DIR:-/tmp}/qmd-handoff.log}}"
WORKER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --worker)
      WORKER=1
      shift
      ;;
    --log)
      if [ $# -ge 2 ]; then
        LOG="$2"
        shift 2
      else
        shift
      fi
      ;;
    --log=*)
      LOG="${1#--log=}"
      shift
      ;;
    -h|--help)
      sed -n '2,32p' "$0"
      exit 0
      ;;
    *) shift ;;
  esac
done

# -------- agent hard-skip (MUST run before any command -v qmd) --------
# Established markers (ANY → skipped-agent). Never invoke qmd or managed wrappers.
is_agent_box() {
  case "${HQ_QMD_REINDEX_MODE:-}" in
    skip-agent|skip) return 0 ;;
  esac
  if [ -n "${HQ_AGENT_BOX:-}" ] && [ "${HQ_AGENT_BOX}" != "0" ]; then
    return 0
  fi
  # File markers only (no systemctl is-enabled on the hot path).
  if [ -x /usr/local/bin/hq-agent-qmd-index ] \
    || [ -x /usr/local/lib/hq-agent/qmd-index-user ] \
    || [ -f /etc/systemd/system/hq-agent-qmd-index.timer ] \
    || [ -f /etc/systemd/system/hq-agent-qmd-index.service ]; then
    return 0
  fi
  # Sole agent state dir is sufficient (do not require companion workdir).
  if [ -d /var/lib/hq-agent ]; then
    return 0
  fi
  return 1
}

if [ "$WORKER" -eq 0 ]; then
  # ---- Launcher: agent first, then empty-HOME / missing-qmd, then detach ----
  # HQ_AGENT_BOX=1 with qmd absent must print skipped-agent (not skipped).
  if is_agent_box; then
    echo "skipped-agent" >>"$LOG" 2>/dev/null || true
    echo "skipped-agent"
    exit 0
  fi

  # Empty HOME: no laptop mutation (no locks, no qmd). Quiet exit 0.
  if [ -z "${HOME:-}" ]; then
    exit 0
  fi

  if ! command -v qmd >/dev/null 2>&1; then
    echo "skipped"
    exit 0
  fi

  # Spawn worker detached; print real child PID so finalize JSON is honest.
  nohup bash "$_SELF" --worker --log "$LOG" </dev/null >/dev/null 2>&1 &
  echo $!
  exit 0
fi

# =====================================================================
# Worker mode: portable single-flight lock + pipeline. Never respawns.
# =====================================================================

# Agent re-check before qmd lookup (env may have changed; never mutate agents).
if is_agent_box; then
  exit 0
fi

# Empty HOME: no locks under /tmp or shared roots; no qmd. Quiet exit 0.
if [ -z "${HOME:-}" ]; then
  exit 0
fi

if ! command -v qmd >/dev/null 2>&1; then
  exit 0
fi

# Lock root: only ${HOME}/.hq/locks (never ~/.hq-agent managed lock domain).
LOCK_ROOT="${HOME}/.hq/locks"
mkdir -p "$LOCK_ROOT" 2>/dev/null || true

LOCK_DIR="${LOCK_ROOT}/qmd-reindex-bg.lock"
OWNER_FILE="${LOCK_DIR}/owner"
COMPLETE_STAMP="${LOCK_ROOT}/qmd-reindex-bg.completed"
DEDUPE_SEC="${QMD_HANDOFF_DEDUPE_SEC:-90}"
LOG_MAX_BYTES="${QMD_HANDOFF_LOG_MAX_BYTES:-65536}"
LOCK_GRACE_SEC="${QMD_HANDOFF_LOCK_GRACE_SEC:-5}"

now_epoch() {
  date +%s 2>/dev/null || echo 0
}

log_ts() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date
}

run_qmd() {
  # ionice is Linux-only; never let its absence skip qmd (macOS).
  if command -v ionice >/dev/null 2>&1; then
    nice -n 19 ionice -c 3 "$@"
  else
    nice -n 19 "$@"
  fi
}

lock_mtime() {
  if stat -c %Y "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  if stat -f %m "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  echo 0
}

# Quiet skip when a recent *successful* flight already finished. Collapses
# sequential finalize → post without sleeping. Failed updates leave no stamp
# so post still gets a second chance.
recently_completed() {
  local last now
  case "${DEDUPE_SEC}" in
    ''|*[!0-9]*) return 1 ;;
    0) return 1 ;;
  esac
  [ -f "$COMPLETE_STAMP" ] || return 1
  last="$(awk -F= '/^ts=/{print $2; exit}' "$COMPLETE_STAMP" 2>/dev/null || true)"
  case "${last}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  now="$(now_epoch)"
  [ "$now" -ge "$last" ] 2>/dev/null || return 1
  [ $((now - last)) -lt "$DEDUPE_SEC" ] 2>/dev/null
}

write_completion_stamp() {
  {
    echo "ts=$(now_epoch)"
    echo "pid=$$"
    echo "mode=raw"
  } >"$COMPLETE_STAMP" 2>/dev/null || true
}

write_owner_record() {
  {
    echo "pid=$$"
    echo "ts=$(now_epoch)"
    echo "nonce=$$.$RANDOM"
  } >"$OWNER_FILE" 2>/dev/null || true
}

owner_is_live() {
  local opid mt now age grace
  [ -d "$LOCK_DIR" ] || return 1

  if [ -f "$OWNER_FILE" ]; then
    opid="$(awk -F= '/^pid=/{print $2; exit}' "$OWNER_FILE" 2>/dev/null || true)"
    case "${opid}" in
      ''|*[!0-9]*) ;;
      *)
        if kill -0 "$opid" 2>/dev/null; then
          return 0
        fi
        return 1
        ;;
    esac
  fi

  grace="${LOCK_GRACE_SEC}"
  case "${grace}" in
    ''|*[!0-9]*) grace=5 ;;
  esac
  mt="$(lock_mtime)"
  case "${mt}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  now="$(now_epoch)"
  age=$((now - mt))
  [ "$age" -lt 0 ] && age=0
  [ "$age" -lt "$grace" ]
}

release_lock() {
  local opid
  if [ -f "$OWNER_FILE" ]; then
    opid="$(awk -F= '/^pid=/{print $2; exit}' "$OWNER_FILE" 2>/dev/null || true)"
    if [ "$opid" = "$$" ]; then
      rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
  fi
}

cap_log() {
  local size max tmp keep
  max="${LOG_MAX_BYTES}"
  case "${max}" in
    ''|*[!0-9]*) return 0 ;;
    0) return 0 ;;
  esac
  [ -f "$LOG" ] || return 0
  size="$(wc -c <"$LOG" 2>/dev/null | tr -d '[:space:]' || echo 0)"
  case "${size}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$size" -gt "$max" ] 2>/dev/null || return 0
  keep="$max"
  tmp="${LOG}.cap.$$"
  if tail -c "$keep" "$LOG" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$LOG" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# Portable mkdir single-flight only (one lock contract). Nonblocking:
# mkdir wins, live owner → busy, dead/stale owner → atomic mv reclaim.
try_acquire_lock() {
  local steal

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    write_owner_record
    return 0
  fi

  if owner_is_live; then
    return 1
  fi

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
  exit 0
fi

if ! try_acquire_lock; then
  # Live owner still flying, or lost reclaim race. Quiet success; no second writer.
  exit 0
fi

trap release_lock EXIT INT TERM HUP

if recently_completed; then
  exit 0
fi

# Winner only: write log and run pipeline under lock.
# cleanup: best-effort; embed only if update succeeds; all failures → exit 0.
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
{
  echo "[qmd-reindex-bg] start worker ts=$(log_ts) pid=$$"
} >"$LOG" 2>/dev/null || true

run_qmd qmd cleanup >>"$LOG" 2>&1 || true

# Stamp only after successful update *and* embed attempt finishes so sequential
# finalize→post within DEDUPE_SEC does not suppress a legitimate embed retry.
# No stamp on update failure — post still gets a second chance.
if run_qmd qmd update >>"$LOG" 2>&1; then
  run_qmd qmd embed >>"$LOG" 2>&1 || true
  write_completion_stamp
  echo "[qmd-reindex-bg] done ts=$(log_ts)" >>"$LOG" 2>&1 || true
  cap_log
else
  echo "[qmd-reindex-bg] update-failed ts=$(log_ts)" >>"$LOG" 2>&1 || true
fi

exit 0
