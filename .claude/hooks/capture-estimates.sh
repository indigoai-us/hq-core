#!/bin/bash
# capture-estimates.sh - Stop hook: scan last assistant message for time estimates.

set -euo pipefail

INPUT=$(cat)

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

[ -z "$TRANSCRIPT_PATH" ] && exit 0
[ -f "$TRANSCRIPT_PATH" ] || exit 0
[ -z "$SESSION_ID" ] && exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
HQ_ROOT="$(cd "$HQ_ROOT/.." && pwd)"

LOG_DIR="$HQ_ROOT/workspace/estimate-log"
LOG_FILE="$LOG_DIR/log.jsonl"
PARSER="$HOOK_DIR/lib/parse-estimates.pl"

[ -x "$PARSER" ] || exit 0

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

LAST_ASSISTANT=$(awk '/"type":"assistant"/ { last=$0 } END { print last }' "$TRANSCRIPT_PATH")
[ -z "$LAST_ASSISTANT" ] && exit 0

UUID=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.uuid // .message.id // empty' 2>/dev/null || echo "")
[ -z "$UUID" ] && exit 0

if [ -s "$LOG_FILE" ] && grep -F "\"message_uuid\":\"$UUID\"" "$LOG_FILE" 2>/dev/null | grep -qF "\"session_id\":\"$SESSION_ID\""; then
    exit 0
fi

TEXT=$(printf '%s' "$LAST_ASSISTANT" | jq -r '
  .message.content as $c
  | if ($c | type) == "array" then
      [$c[] | select(.type == "text") | .text] | join("\n")
    elif ($c | type) == "string" then
      $c
    else "" end
' 2>/dev/null || echo "")

[ -z "$TEXT" ] && exit 0

ISO_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NEW_ENTRIES=$(printf '%s' "$TEXT" | "$PARSER" "$SESSION_ID" "$UUID" "$ISO_TS" 2>/dev/null || echo "")

if [ -n "$NEW_ENTRIES" ]; then
    printf '%s\n' "$NEW_ENTRIES" >> "$LOG_FILE"
fi

exit 0
