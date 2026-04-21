#!/bin/bash
# Stop hook: advisory 60% context warning (once per session).
#
# Fires after every assistant turn. Estimates context usage from transcript
# file size, and prints a one-time advisory banner when usage crosses ~60%.
# Autocompact itself still runs at CLAUDE_AUTOCOMPACT_PCT_OVERRIDE (75% by
# default) — this hook only warns early so the user has runway to decide.
#
# Non-fatal by design: any error is swallowed, script always exits 0.
# Stop hooks must never block session turnaround.

set -uo pipefail

HQ="${HOME}/Documents/HQ"
STATE_DIR="$HQ/workspace/.context-warnings"

# Always succeed — wrap everything so a malformed input never blocks Stop.
{
  INPUT="$(cat 2>/dev/null || echo '{}')"

  # Extract fields from Stop-hook stdin JSON. Silent if jq missing or field absent.
  TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"

  # Need both to proceed.
  if [ -z "$TRANSCRIPT_PATH" ] || [ -z "$SESSION_ID" ]; then
    exit 0
  fi

  # Transcript must exist and be readable.
  if [ ! -r "$TRANSCRIPT_PATH" ]; then
    exit 0
  fi

  # Once-per-session gate.
  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
  STATE_FILE="$STATE_DIR/$SESSION_ID"
  if [ -e "$STATE_FILE" ]; then
    exit 0
  fi

  # Estimate token count from transcript size.
  # Heuristic: ~3.5 chars per token (English-weighted). Good enough for an advisory.
  # Integer math: tokens ~= bytes * 10 / 35. Threshold: 60% of context window.
  # bytes >= 0.60 * window * 3.5  ==>  bytes >= window * 21 / 10.
  CONTEXT_WINDOW="${CLAUDE_CONTEXT_WINDOW:-200000}"
  BYTES="$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo 0)"
  if [ -z "$BYTES" ] || [ "$BYTES" = "0" ]; then
    exit 0
  fi

  THRESHOLD_BYTES=$(( CONTEXT_WINDOW * 21 / 10 ))
  if [ "$BYTES" -lt "$THRESHOLD_BYTES" ]; then
    exit 0
  fi

  # Cross the threshold — mark state and print advisory.
  touch "$STATE_FILE" 2>/dev/null || true

  cat <<'BANNER_EOF'
╔══════════════════════════════════════════════════════════════╗
║  Context ~60% — autocompact at 75%                           ║
╠══════════════════════════════════════════════════════════════╣
║  Heads up: you have runway until 75%. Options:               ║
║                                                              ║
║   • Checkpoint now      — /checkpoint (save, keep working)   ║
║   • Handoff now         — /handoff (wrap up this session)    ║
║   • Continue            — I'll keep going; you decide later  ║
║                                                              ║
║  This warning fires once per session. /handoff anytime.      ║
╚══════════════════════════════════════════════════════════════╝
BANNER_EOF
} 2>/dev/null || true

exit 0
