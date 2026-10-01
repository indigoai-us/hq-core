#!/usr/bin/env bash
# Record legacy write-guard decisions without affecting tool permissions.
# The default-off SessionStart snapshot leaves this marker absent; the registry
# prefilter then skips this child entirely for every PreToolUse event.
set -uo pipefail
export BASH_ENV=/dev/null

INPUT=""
while IFS= read -r line; do INPUT+="$line"; done
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SESSION_ID="$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
case "$SESSION_ID" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
[ "${#SESSION_ID}" -le 128 ] || exit 0
ENABLED_MARKER="$PROJECT_DIR/workspace/orchestrator/hook-state/merged-write-guard-shadow/$SESSION_ID.enabled"
[ -f "$ENABLED_MARKER" ] || exit 0

SCRIPT_PATH="${BASH_SOURCE[0]}"
case "$SCRIPT_PATH" in
  /*/.claude/hooks/merged-write-guard-shadow.sh) HOOK_ROOT="${SCRIPT_PATH%/.claude/hooks/merged-write-guard-shadow.sh}" ;;
  *) exit 0 ;;
esac
printf '%s\n' "$INPUT" | node "$HOOK_ROOT/.claude/hooks/merged-write-guard-shadow.cjs"
# This hook only records a canary decision. Its exit status never participates
# in the tool permission decision, including on flag or log errors.
exit 0
