#!/usr/bin/env bash
# session-title.sh — SessionStart + UserPromptSubmit hook.
#
# Sets the Claude Code session title (desktop sidebar "Recents" / terminal tab
# title / `/resume` picker) to an HQ status string:
#     {status-emoji }{company} · {project} · {command}
#
# The title string is computed by core/scripts/session-title.sh. This wrapper
# detects the active slash command from the prompt, persists it across turns,
# and emits hookSpecificOutput.sessionTitle — but ONLY when the title actually
# changes (live, change-only cadence).
#
# Opt out:  HQ_SESSION_TITLE=off (or 0/false/no)  |  HQ_DISABLED_HOOKS=session-title
set -uo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
HELPER="$HQ_ROOT/core/scripts/session-title.sh"
STATE_DIR="$HQ_ROOT/.claude/state"

case "${HQ_SESSION_TITLE:-on}" in
  0|false|FALSE|off|OFF|no|NO) exit 0 ;;
esac

[ -x "$HELPER" ] || exit 0

extract() {
  printf '%s' "$STDIN_JSON" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    v=d.get(sys.argv[1],"")
    sys.stdout.write(str(v if v is not None else ""))
except Exception:
    pass
' "$1" 2>/dev/null || true
}

EVENT="$(extract hook_event_name)"
SOURCE="$(extract source)"
PROMPT="$(extract prompt)"
SESSION_ID="$(extract session_id)"
[ -z "$SESSION_ID" ] && SESSION_ID="default"

# Infer the event if Claude Code did not provide hook_event_name.
if [ -z "$EVENT" ]; then
  if [ -n "$PROMPT" ]; then EVENT="UserPromptSubmit"; else EVENT="SessionStart"; fi
fi

# SessionStart sessionTitle is ignored on clear/compact — skip those.
if [ "$EVENT" = "SessionStart" ]; then
  case "$SOURCE" in clear|compact) exit 0 ;; esac
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
SESSION_KEY="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$SESSION_KEY" ] || SESSION_KEY="default"
STATE="$STATE_DIR/session-title-${SESSION_KEY}"

# State file: line 1 = last command word, line 2 = last emitted title.
last_command=""; last_title=""
if [ -f "$STATE" ]; then
  last_command="$(sed -n '1p' "$STATE" 2>/dev/null || true)"
  last_title="$(sed -n '2p' "$STATE" 2>/dev/null || true)"
fi

# Detect a leading slash command in this prompt (UserPromptSubmit only); the
# command word persists across turns until a new command is issued.
command="$last_command"
if [ "$EVENT" = "UserPromptSubmit" ] && [ -n "$PROMPT" ]; then
  detected="$(printf '%s' "$PROMPT" | python3 -c '
import sys,re
t=sys.stdin.read().lstrip()
m=re.match(r"/([A-Za-z0-9:_-]+)", t)
if m:
    sys.stdout.write(m.group(1).split(":")[-1])
' 2>/dev/null || true)"
  [ -n "$detected" ] && command="$detected"
fi

title="$("$HELPER" --session-id "$SESSION_ID" --command "$command" 2>/dev/null || true)"
[ -n "$title" ] || exit 0

# Persist the command regardless; only emit when the title actually changed.
if [ "$title" = "$last_title" ]; then
  printf '%s\n%s\n' "$command" "$last_title" > "$STATE" 2>/dev/null || true
  exit 0
fi

printf '%s\n%s\n' "$command" "$title" > "$STATE" 2>/dev/null || true

jq -n --arg ev "$EVENT" --arg t "$title" '{
  hookSpecificOutput: {
    hookEventName: $ev,
    sessionTitle: $t
  }
}'
exit 0
