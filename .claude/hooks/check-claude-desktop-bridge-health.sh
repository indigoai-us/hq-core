#!/bin/bash
# SessionStart health check: detect zombie Claude desktop bridge sessions.
#
# Reads bridge-state.json plus recent Claude desktop logs. Warn ONLY when BOTH
# signals fire:
#   1. bridge-state.json has enabled:true + processedMessageUuids:[]
#   2. main*.log shows the Apr-10 leak patterns
#
# Tightened 2026-04-15: the file signature alone is the normal resting state of
# a healthy bridge, so the hook now requires corroborating log evidence.
#
# Always exits 0 - this is advisory, not a blocker.

set -euo pipefail

# Consume stdin (gate passes it even if empty)
cat >/dev/null 2>&1 || true

if [ -z "${BRIDGE_STATE_FILE:-}" ]; then
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin) ;;
    *)
      # Cowork and other non-desktop runtimes do not expose Claude desktop
      # bridge state; skip immediately instead of probing macOS-only paths.
      exit 0
      ;;
  esac
fi

BRIDGE_STATE="${BRIDGE_STATE_FILE:-$HOME/Library/Application Support/Claude/bridge-state.json}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/Claude}"
LOG_FILE_OVERRIDE="${LOG_FILE:-}"

# Staleness threshold: if bridge-state.json is older than this AND logs are
# clean, skip entirely. Apr 10 leak accumulated over 8 days, so 7 days is a
# safe floor that still surfaces any genuinely-active leak.
STALE_DAYS=7

# Tail window on each log file - covers roughly an hour of a noisy bridge.
LOG_TAIL_LINES=5000

file_mtime() {
  local path="$1"
  local mtime=""
  mtime="$(stat -f %m "$path" 2>/dev/null || true)"
  if [ -n "$mtime" ]; then
    printf '%s' "$mtime"
    return 0
  fi
  mtime="$(stat -c %Y "$path" 2>/dev/null || true)"
  if [ -n "$mtime" ]; then
    printf '%s' "$mtime"
  fi
}

# Fast exit if file missing (Cowork not configured, or freshly cleared)
[ ! -f "$BRIDGE_STATE" ] && exit 0

# Need jq for safe JSON parsing.
command -v jq >/dev/null 2>&1 || exit 0

# Signal 1: file-level zombie signature.
FILE_MATCH="$(jq -r '
  [.[] | select(.enabled == true and (.processedMessageUuids // [] | length) == 0)] | length
' "$BRIDGE_STATE" 2>/dev/null || echo 0)"

[ "${FILE_MATCH:-0}" -eq 0 ] && exit 0

# Signal 2: log-level discriminators.
LOG_MATCH=0
if [ -n "$LOG_FILE_OVERRIDE" ] && [ -f "$LOG_FILE_OVERRIDE" ]; then
  LOG_MATCH="$(tail -n "$LOG_TAIL_LINES" "$LOG_FILE_OVERRIDE" 2>/dev/null \
    | grep -cE 'Transport permanently closed.*code=4090|Cap-redispatch budget exhausted' \
    || true)"
elif [ -d "$LOG_DIR" ]; then
  for log in "$LOG_DIR"/main.log "$LOG_DIR"/main1.log; do
    [ -f "$log" ] || continue
    hits="$(tail -n "$LOG_TAIL_LINES" "$log" 2>/dev/null \
      | grep -cE 'Transport permanently closed.*code=4090|Cap-redispatch budget exhausted' \
      || true)"
    LOG_MATCH=$((LOG_MATCH + hits))
  done
fi

# Staleness escape valve.
if [ "${LOG_MATCH:-0}" -eq 0 ]; then
  mtime="$(file_mtime "$BRIDGE_STATE" || true)"
  if [ -n "$mtime" ]; then
    now="$(date +%s)"
    age_days=$(( (now - mtime) / 86400 ))
    if [ "$age_days" -ge "$STALE_DAYS" ]; then
      exit 0
    fi
  fi
  # Logs clean + file recent means normal resting state, not a zombie.
  exit 0
fi

cat <<EOF
<bridge-health-warning>
Claude desktop bridge-state.json zombie session detected.

Correlated evidence:
  - bridge-state.json: $FILE_MATCH entry/entries with enabled=true + processedMessageUuids=[]
  - main*.log: $LOG_MATCH leak-pattern hit(s) in the last $LOG_TAIL_LINES lines
    (Transport permanently closed code=4090 / Cap-redispatch budget exhausted)

This is the pattern that caused a 260 GB memory leak on 2026-04-10.

Mitigation:
  1. Quit Claude desktop: osascript -e 'tell application "Claude" to quit'
  2. Backup: cp "$BRIDGE_STATE" "${BRIDGE_STATE}.bak-\$(date +%s)"
  3. Delete: rm "$BRIDGE_STATE"
  4. Restart Claude desktop - bridge regenerates clean on next consent

File: $BRIDGE_STATE
Logs: $LOG_DIR/main*.log
</bridge-health-warning>
EOF

exit 0
