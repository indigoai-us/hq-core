#!/usr/bin/env bash
# PostToolUse hook — emits "JOURNAL ENTRY DUE" reminders at milestone boundaries.
#
# Triggers (any one):
#   - Every 10 successful Edit/Write/MultiEdit tool calls (counted)
#   - Successful `git commit` (matched by command + non-zero $? from tool_response would
#     normally be available, but we only have stdin JSON; we match on command string)
#   - Successful test/typecheck/lint run (heuristic via tool input command match)
#
# Reads the PostToolUse JSON from stdin (Claude Code hook contract). Emits nothing
# to stdout unless a journal reminder is due — Claude Code surfaces stdout as
# a system reminder in the next turn. Always exits 0.
#
# Counter state: workspace/threads/journal/<today>/.tool-count
#
# Suppress with HQ_DISABLED_HOOKS=journal-due (handled by hook-gate.sh wrapper).

set -uo pipefail

HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOURNAL_HELPER="$HQ_ROOT/core/scripts/session-journal.sh"

# Read stdin JSON (fail-soft if absent or invalid).
stdin_json=""
if [ -t 0 ]; then
  exit 0
fi
stdin_json=$(cat || true)
[ -z "$stdin_json" ] && exit 0

# Extract tool name + tool input command (best-effort).
tool_name=$(printf '%s' "$stdin_json" \
  | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)
  print(d.get("tool_name",""))
except Exception:
  pass' 2>/dev/null)
tool_cmd=$(printf '%s' "$stdin_json" \
  | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)
  ti=d.get("tool_input",{})
  print(ti.get("command","") if isinstance(ti, dict) else "")
except Exception:
  pass' 2>/dev/null)

THRESHOLD=10
should_remind=0
reason=""

case "$tool_name" in
  Edit|Write|MultiEdit|NotebookEdit)
    n=$("$JOURNAL_HELPER" tool-counter increment 2>/dev/null; "$JOURNAL_HELPER" tool-counter read 2>/dev/null)
    if [ -n "$n" ] && [ "$n" -ge "$THRESHOLD" ] 2>/dev/null; then
      should_remind=1
      reason="$THRESHOLD edits since last entry"
    fi
    ;;
  Bash)
    # Detect milestone shell commands by substring (cheap heuristic).
    if echo "$tool_cmd" | grep -qE '(^|[;&|[:space:]])git commit([[:space:]]|$)'; then
      should_remind=1
      reason="git commit"
    elif echo "$tool_cmd" | grep -qE '(^|[;&|[:space:]])(npm|pnpm|yarn|bun) (test|run test|t)(\b|$)'; then
      should_remind=1
      reason="tests run"
    elif echo "$tool_cmd" | grep -qE '(^|[;&|[:space:]])(pytest|cargo test|go test|tsc|tsc --noEmit|eslint|biome check|ruff check)(\b|$)'; then
      should_remind=1
      reason="test/typecheck/lint run"
    fi
    ;;
esac

if [ "$should_remind" = "1" ]; then
  # Soft signal — surfaced to Claude as system reminder.
  cat <<EOF
JOURNAL ENTRY DUE — trigger: $reason

The session has reached a milestone where the working memory is worth distilling
into a journal entry. Write one now (or soon) so autocompact can safely discard
the raw tool-results currently in the prefix.

  /journal "<title>"

Spec: core/knowledge/public/hq-core/journal-spec.md
EOF
fi

exit 0
