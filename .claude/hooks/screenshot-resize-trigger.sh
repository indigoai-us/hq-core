#!/bin/bash
# PostToolUse hook: after any Bash call that runs agent-browser screenshot,
# resize the output file to max 1800px before Claude reads it back.
# Also tracks cumulative screenshot count and injects warnings at thresholds.

set -euo pipefail

HQ="${HOME}/Documents/HQ"
RESIZE="$HQ/scripts/resize-screenshot.sh"
COUNT_FILE="/tmp/hq-screenshot-count-${PPID}"
WARN_THRESHOLD=30
HARD_THRESHOLD=45

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

[[ "$TOOL_NAME" == "Bash" ]] || exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Only trigger on agent-browser screenshot commands
echo "$CMD" | grep -qE 'agent-browser.*screenshot' || exit 0

# Extract file path from the command (agent-browser screenshot <path>)
SCREENSHOT_PATH=$(echo "$CMD" | grep -oE '/[^ ]+\.(png|jpg|jpeg)' | head -1 || true)

if [[ -n "$SCREENSHOT_PATH" && -f "$SCREENSHOT_PATH" ]]; then
  bash "$RESIZE" "$SCREENSHOT_PATH" 2>/dev/null || true
fi

# Track count
COUNT=0
[[ -f "$COUNT_FILE" ]] && COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
COUNT=$(( COUNT + 1 ))
echo "$COUNT" > "$COUNT_FILE"

if [[ "$COUNT" -eq "$WARN_THRESHOLD" ]]; then
  echo ""
  echo "⚠ SCREENSHOT WARNING: $COUNT screenshots this session."
  echo "Claude API many-image mode active (2000px limit). Screenshots auto-resized to 1800px."
  echo "Consider: use sub-agents for screenshot analysis, or /handoff after this batch."
  echo ""
fi

if [[ "$COUNT" -ge "$HARD_THRESHOLD" ]]; then
  echo ""
  echo "🛑 SCREENSHOT HARD LIMIT: $COUNT screenshots. Context heavily loaded."
  echo "MANDATORY: Run /handoff after completing current page. Resume audit in fresh session."
  echo ""
fi

exit 0
