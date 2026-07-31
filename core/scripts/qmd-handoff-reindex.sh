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
# Logging / process discipline
#   - One bounded log (default /tmp/qmd-handoff.log; override via
#     QMD_HANDOFF_LOG, or HANDOFF_LOG_DIR/qmd-handoff.log).
#   - Only the lock winner truncates/writes the log.
#   - No unbounded retry loop; failures stay non-blocking (always exit 0).
#   - Managed component stamp owns health on agent boxes.
#
# Env (production defaults; overrides are for tests / rare diagnostics)
#   HQ_QMD_INDEX_USER  managed user-half path
#   QMD_HANDOFF_LOG    full log path
#   HANDOFF_LOG_DIR    log directory when QMD_HANDOFF_LOG unset (default /tmp)
#   HOME               lock root parent (${HOME}/.hq/locks/)
#
# Exit: always 0 (handoff must not block on search reindex).

set -u

# Resolve log path without truncating yet — busy callers must not wipe a
# winner's evidence.
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

# Portable nonblocking user lock (mkdir). Shared across finalize + post and
# overlapping handoffs so at most one mutation runs.
LOCK_ROOT="${HOME:-}/.hq/locks"
if [[ -z "${HOME:-}" ]]; then
  # No HOME → cannot take a user lock safely; skip rather than race.
  exit 0
fi
mkdir -p "$LOCK_ROOT" 2>/dev/null || true
LOCK_DIR="${LOCK_ROOT}/qmd-handoff-reindex.lock"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # Busy: another handoff reindex owns the flight. Quiet success; do not
  # touch the shared log.
  exit 0
fi

release_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap release_lock EXIT INT TERM HUP

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

exit 0
