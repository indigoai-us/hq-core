#!/bin/bash
# Stop hook: mandatory 50% context checkpoint (once per session).
#
# Fires after every assistant turn. Estimates context usage from transcript
# file size, and prints a one-time checkpoint directive when usage crosses ~50%.
# Autocompact itself still runs at CLAUDE_AUTOCOMPACT_PCT_OVERRIDE (60% by
# default) — this hook fires early so /checkpoint can run while enough context
# remains to preserve state and, if useful, orchestrate subagents.
#
# Non-fatal by design: any error is swallowed, script always exits 0.
# Stop hooks must never block session turnaround.

set -uo pipefail

HQ="${CLAUDE_PROJECT_DIR:-${HQ_ROOT:-${HOME}/Documents/HQ}}"
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
  SESSION_KEY="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_')"
  if [ -z "$SESSION_KEY" ]; then
    exit 0
  fi

  # Transcript must exist and be readable.
  if [ ! -r "$TRANSCRIPT_PATH" ]; then
    exit 0
  fi

  # Once-per-session gate.
  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
  STATE_FILE="$STATE_DIR/$SESSION_KEY"
  if [ -e "$STATE_FILE" ]; then
    exit 0
  fi

  # Estimate token count from transcript size.
  # Heuristic: ~3.5 chars per token (English-weighted). Good enough for an advisory.
  # Integer math: tokens ~= bytes * 10 / 35. Threshold: 50% of context window.
  # bytes >= 0.50 * window * 3.5  ==>  bytes >= window * 7 / 4.
  CONTEXT_WINDOW="${CLAUDE_CONTEXT_WINDOW:-1000000}"
  BYTES="$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo 0)"
  if [ -z "$BYTES" ] || [ "$BYTES" = "0" ]; then
    exit 0
  fi

  THRESHOLD_BYTES=$(( CONTEXT_WINDOW * 7 / 4 ))
  if [ "$BYTES" -lt "$THRESHOLD_BYTES" ]; then
    exit 0
  fi

  # Cross the threshold — mark state and print mandatory checkpoint directive.
  touch "$STATE_FILE" 2>/dev/null || true

  cat <<'BANNER_EOF'
╔══════════════════════════════════════════════════════════════╗
║  AUTO-CHECKPOINT REQUIRED — context ~50%                     ║
╠══════════════════════════════════════════════════════════════╣
║  Run /checkpoint now before continuing work.                 ║
║                                                              ║
║  This fires while there is still enough context to preserve  ║
║  session state and delegate follow-up work if needed.        ║
║                                                              ║
║  Do not ask the user first. Do not continue normal task work ║
║  until the checkpoint is complete.                           ║
╚══════════════════════════════════════════════════════════════╝
BANNER_EOF
} 2>/dev/null || true

exit 0
