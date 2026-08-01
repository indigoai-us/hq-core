#!/usr/bin/env bash
# qmd-reindex-bg.sh — single-flight background search reindex for handoff/sync.
#
# Ownership (agent handoff+qmd plan):
#   - Hosted agent boxes: NEVER mutate qmd from handoff. Managed timer/indexer
#     owns all update/embed. Print "skipped-agent" so callers can record it.
#   - Laptop / non-agent HQ: one flock-guarded nohup of cleanup → update → embed.
#
# Seatbelt: PATH /usr/local/bin/qmd shim still flock-serializes any stray raw
# embed on agent boxes (toolset). This helper simply refuses to start work.
#
# Usage (fire-and-forget; prints token/PID on stdout):
#   core/scripts/qmd-reindex-bg.sh
#   core/scripts/qmd-reindex-bg.sh --log /tmp/qmd-handoff.log
#
# Exit 0 always for callers that must not fail handoff.

set -u

LOG="${QMD_REINDEX_LOG:-/tmp/qmd-handoff.log}"
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *) shift ;;
  esac
done

# Explicit skip (ritual/toolset can force this even on laptop for tests).
if [ "${HQ_QMD_REINDEX_MODE:-}" = "skip-agent" ] || [ "${HQ_QMD_REINDEX_MODE:-}" = "skip" ]; then
  echo "skipped-agent" >>"$LOG" 2>/dev/null || true
  echo "skipped-agent"
  exit 0
fi

if ! command -v qmd >/dev/null 2>&1; then
  echo "skipped"
  exit 0
fi

# ---- Hosted agent box: indexer owns mutation; handoff does not kick ----
_agent_box=0
if [ -n "${HQ_AGENT_BOX:-}" ] && [ "${HQ_AGENT_BOX}" != "0" ]; then
  _agent_box=1
fi
if [ -x /usr/local/bin/hq-agent-qmd-index ] \
  || [ -x /usr/local/lib/hq-agent/qmd-index-user ] \
  || [ -f /etc/systemd/system/hq-agent-qmd-index.timer ] \
  || [ -f /etc/systemd/system/hq-agent-qmd-index.service ] \
  || systemctl is-enabled hq-agent-qmd-index.timer >/dev/null 2>&1; then
  _agent_box=1
fi
if [ -d /var/lib/hq-agent ] && { [ -d /home/ec2-user/hq-agent ] || [ -d "${AGENT_WORKDIR:-}" ]; }; then
  _agent_box=1
fi

if [ "$_agent_box" -eq 1 ]; then
  # Freshness: timer (15m lexical) + post-sync qmd-need-lexical flag (indexer).
  # Handoff must not systemctl-start the full oneshot (can arm embed under load).
  echo "skipped-agent" >>"$LOG" 2>/dev/null || true
  echo "skipped-agent"
  exit 0
fi

# ---- Laptop / non-agent: single-flight raw reindex ----
LOCK_DIR="${HOME:-/tmp}/.hq-agent"
mkdir -p "$LOCK_DIR" 2>/dev/null || LOCK_DIR="/tmp"
LOCK_FILE="${LOCK_DIR}/qmd-index.lock"

nohup bash -c "
  exec 9>\"${LOCK_FILE}\" || exit 0
  flock -n 9 || exit 0
  {
    echo \"[qmd-reindex-bg] start \$(date -Iseconds)\"
    nice -n 19 ionice -c 3 qmd cleanup 2>/dev/null || true
    nice -n 19 ionice -c 3 qmd update 2>/dev/null || true
    nice -n 19 ionice -c 3 qmd embed 2>/dev/null || true
    echo \"[qmd-reindex-bg] done \$(date -Iseconds)\"
  } >>\"${LOG}\" 2>&1
" >/dev/null 2>&1 &
echo $!
exit 0
