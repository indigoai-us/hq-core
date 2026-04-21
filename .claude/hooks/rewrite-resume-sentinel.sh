#!/bin/bash
# rewrite-resume-sentinel.sh — UserPromptSubmit hook
#
# Detects Claude Code's synthetic resume message ("Continue from where you left
# off.") and injects corrective additionalContext telling the model to read
# handoff state and produce an actionable reply.
#
# Fixes the "No response requested" failure mode where Opus 4.6 mis-classifies
# the bare resume sentinel as a non-interactive notification and replies with a
# terse null-op instead of continuing work.
#
# See: .claude/plans/mighty-noodling-parasol.md
#
# Trigger: UserPromptSubmit
# Exit codes: 0 = always allow (additive context only)

set -euo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"

# Extract "prompt" field via python3 (reliable JSON unescaping)
PROMPT="$(printf '%s' "$STDIN_JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    sys.stdout.write(d.get("prompt", ""))
except Exception:
    pass
' 2>/dev/null || echo "")"

# Normalize: strip whitespace, lowercase, strip trailing period
NORMALIZED="$(printf '%s' "$PROMPT" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')"
SENTINEL="continuefromwhereyouleftoff"

if [ "$NORMALIZED" = "$SENTINEL" ]; then
  # Telemetry — fire-and-forget append to learnings log
  HQ_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/Documents/HQ")"
  LOG_DIR="$HQ_ROOT/workspace/learnings"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  SESSION_ID="$(printf '%s' "$STDIN_JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    sys.stdout.write(d.get("session_id", "unknown"))
except Exception:
    sys.stdout.write("unknown")
' 2>/dev/null || echo "unknown")"
  printf '{"ts":"%s","event":"resume-sentinel-rewrite","session":"%s"}\n' "$TS" "$SESSION_ID" \
    >> "$LOG_DIR/resume-sentinel.jsonl" 2>/dev/null || true

  # Emit JSON to append additionalContext to the prompt submission
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[resume-sentinel-hook] The only content of this user turn is Claude Code's synthetic resume message 'Continue from where you left off.' There is no new user question. To continue the prior session: (1) Read workspace/threads/handoff.json for the last session state. (2) In 1-2 sentences, summarize what was in progress and what the next unfinished task is. (3) Proceed with that task, or ask the user a concrete question if blocked. Do NOT reply with 'No response requested' or a terse acknowledgment — always produce an actionable reply."}}
JSON
fi

exit 0
