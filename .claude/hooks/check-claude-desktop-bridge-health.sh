#!/bin/bash
# SessionStart health check: detect zombie Claude desktop bridge sessions.
#
# Reads ~/Library/Application Support/Claude/bridge-state.json and
# ~/Library/Logs/Claude/main*.log. Warns ONLY when BOTH signals fire:
#   1. bridge-state.json has an entry with enabled:true + processedMessageUuids:[]
#   2. main*.log shows the Apr-10 leak patterns (Transport permanently closed
#      code=4090, Cap-redispatch budget exhausted) in recent tail
#
# Tightened 2026-04-15: the file signature alone is the normal resting state of
# a healthy bridge, so the original hook produced a false positive every session.
# Gating on log evidence restores signal-to-noise and matches the 3-of-4 rule in
# policy claude-desktop-bridge-state-zombie.md.
#
# Always exits 0 — this is advisory, not a blocker.
# Policy reference: .claude/policies/claude-desktop-bridge-state-zombie.md

set -euo pipefail

# Consume stdin (gate passes it even if empty)
cat >/dev/null 2>&1 || true

BRIDGE_STATE="$HOME/Library/Application Support/Claude/bridge-state.json"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/Claude}"
# Override via env var for testing: LOG_FILE=/tmp/fake.log ...
LOG_FILE_OVERRIDE="${LOG_FILE:-}"

# Staleness threshold: if bridge-state.json is older than this AND logs are
# clean, skip entirely. Apr 10 leak accumulated over 8 days, so 7 days is a
# safe floor that still surfaces any genuinely-active leak.
STALE_DAYS=7

# Tail window on each log file — covers ~1h of a noisy bridge, cheap to grep.
LOG_TAIL_LINES=5000

# Fast exit if file missing (Cowork not configured, or freshly cleared)
[ ! -f "$BRIDGE_STATE" ] && exit 0

# Need jq for safe JSON parsing (available on all HQ dev machines — used by 9 other hooks)
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# --- Signal 1: file-level zombie signature ---
# The file is a flat object keyed by "{orgId}:{accountId}". Each value is a session.
# Zombie signature: enabled=true AND processedMessageUuids is empty array.
FILE_MATCH=$(jq -r '
  [.[] | select(.enabled == true and (.processedMessageUuids // [] | length) == 0)] | length
' "$BRIDGE_STATE" 2>/dev/null || echo 0)

# No file match → nothing to do. Most common path.
if [ "${FILE_MATCH:-0}" -eq 0 ]; then
  exit 0
fi

# --- Signal 2: log-level discriminators ---
# The policy requires at least one of these patterns to confirm an active leak:
#   - "[sessions-bridge] Transport permanently closed ... code=4090"
#   - "[sessions-bridge] Cap-redispatch budget exhausted"
# Count hits across main.log + main1.log (rotation pair). Use a regex that
# matches the exact leak phrases to avoid false positives from unrelated chatter.
LOG_MATCH=0
if [ -n "$LOG_FILE_OVERRIDE" ] && [ -f "$LOG_FILE_OVERRIDE" ]; then
  LOG_MATCH=$(tail -n "$LOG_TAIL_LINES" "$LOG_FILE_OVERRIDE" 2>/dev/null \
    | grep -cE 'Transport permanently closed.*code=4090|Cap-redispatch budget exhausted' \
    || true)
elif [ -d "$LOG_DIR" ]; then
  for log in "$LOG_DIR"/main.log "$LOG_DIR"/main1.log; do
    [ -f "$log" ] || continue
    hits=$(tail -n "$LOG_TAIL_LINES" "$log" 2>/dev/null \
      | grep -cE 'Transport permanently closed.*code=4090|Cap-redispatch budget exhausted' \
      || true)
    LOG_MATCH=$((LOG_MATCH + hits))
  done
fi

# --- Staleness escape valve ---
# If the bridge-state.json hasn't been touched in STALE_DAYS AND the logs are
# clean, the file is a leftover consent from an idle bridge — not an active
# leak. Skip the warning explicitly so users who set-and-forget Cowork don't
# get nagged forever.
if [ "${LOG_MATCH:-0}" -eq 0 ]; then
  # BSD stat (macOS): -f %m returns mtime epoch seconds.
  if mtime=$(stat -f %m "$BRIDGE_STATE" 2>/dev/null); then
    now=$(date +%s)
    age_days=$(( (now - mtime) / 86400 ))
    if [ "$age_days" -ge "$STALE_DAYS" ]; then
      exit 0
    fi
  fi
  # Logs clean + file recent → normal resting state, not a zombie. Suppress.
  exit 0
fi

# --- Both signals fire → genuine zombie candidate ---
cat <<EOF
<bridge-health-warning>
⚠️  Claude desktop bridge-state.json zombie session detected.

Correlated evidence:
  • bridge-state.json: $FILE_MATCH entry/entries with enabled=true + processedMessageUuids=[]
  • main*.log: $LOG_MATCH leak-pattern hit(s) in last $LOG_TAIL_LINES lines
    (Transport permanently closed code=4090 / Cap-redispatch budget exhausted)

This is the pattern that caused a 260 GB memory leak on 2026-04-10.

Mitigation (from policy claude-desktop-bridge-state-zombie):
  1. Quit Claude desktop: osascript -e 'tell application "Claude" to quit'
  2. Backup: cp "$BRIDGE_STATE" "${BRIDGE_STATE}.bak-\$(date +%s)"
  3. Delete: rm "$BRIDGE_STATE"
  4. Restart Claude desktop — bridge regenerates clean on next consent

File: $BRIDGE_STATE
Logs: $LOG_DIR/main*.log
Full policy: .claude/policies/claude-desktop-bridge-state-zombie.md
</bridge-health-warning>
EOF

exit 0
