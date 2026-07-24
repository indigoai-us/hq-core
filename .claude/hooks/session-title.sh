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
# Manual-rename back-off: once the user sets their own title (launcher
# `claude --name`, `/rename`, or the desktop "Recents" rename), HQ must stop
# overwriting it. We record every title HQ emits in ${STATE}.emitted; any title
# Claude Code surfaces that HQ never emitted is a manual title, so we mark the
# session (${STATE}.manual) and permanently stop emitting for it. The PRIMARY,
# version-stable signal is the documented `session_title` SessionStart hook
# input; the transcript `custom-title` scan is a labeled secondary net for a
# mid-session /rename that the input field does not (yet) reflect.
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

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

extract() {
  printf '%s' "$STDIN_JSON" | hq_json_get "$1"
}

EVENT="$(extract hook_event_name)"
SOURCE="$(extract source)"
PROMPT="$(extract prompt)"
SESSION_ID="$(extract session_id)"
TRANSCRIPT="$(extract transcript_path)"
# Documented, version-stable SessionStart field: Claude Code populates it with
# the user's title when the session was named via --name or renamed via /rename.
SESSION_TITLE_INPUT="$(extract session_title)"
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
EMITTED="$STATE.emitted"   # ledger of titles HQ has emitted this session
MANUAL="$STATE.manual"     # marker: a manual title was seen -> stop emitting

# --- manual-rename back-off -------------------------------------------------
# Permanent back-off once a manual title has been detected for this session.
[ -f "$MANUAL" ] && exit 0

hq_emitted_title() {
  # Did HQ previously emit TITLE ($1)? (exact-line match in the ledger)
  [ -f "$EMITTED" ] || return 1
  grep -qxF -- "$1" "$EMITTED" 2>/dev/null
}

mark_manual() {
  : > "$MANUAL" 2>/dev/null || true
}

transcript_custom_title() {
  # Newest custom-title value from a Claude Code transcript .jsonl, or "".
  # Transcript format is internal/version-fragile — used only as a fallback net.
  local f="$1" last=""
  last="$(grep -F '"custom-title"' "$f" 2>/dev/null | tail -n 1)"
  [ -n "$last" ] || { printf '%s' ""; return 0; }
  printf '%s' "$last" | hq_json_get 'title'
}

# PRIMARY: the documented session_title input. Empty on an unnamed session; set
# to the user's title after --name or /rename. If it is a title HQ never
# emitted, the user owns the title — back off permanently.
if [ -n "$SESSION_TITLE_INPUT" ] && ! hq_emitted_title "$SESSION_TITLE_INPUT"; then
  mark_manual
  exit 0
fi

# SECONDARY (labeled fallback): a mid-session /rename may not be reflected in the
# SessionStart input, so scan the transcript for the newest custom-title line.
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  ct="$(transcript_custom_title "$TRANSCRIPT")"
  if [ -n "$ct" ] && ! hq_emitted_title "$ct"; then
    mark_manual
    exit 0
  fi
fi

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
  # First non-blank content must open with /command; keep the last :segment
  # (mirrors the old lstrip + regex + split(":")[-1] semantics).
  detected="$(printf '%s' "$PROMPT" | awk '
    !found && /[^ \t]/ {
      found = 1
      line = $0; sub(/^[ \t]+/, "", line)
      if (match(line, /^\/[A-Za-z0-9:_-]+/)) {
        s = substr(line, RSTART + 1, RLENGTH - 1)
        n = split(s, a, ":"); print a[n]
      }
    }' 2>/dev/null || true)"
  [ -n "$detected" ] && command="$detected"
fi

title="$("$HELPER" --session-id "$SESSION_ID" --command "$command" 2>/dev/null || true)"
[ -n "$title" ] || exit 0

record_emitted() {
  # Append TITLE ($1) to the HQ-emitted ledger, once.
  hq_emitted_title "$1" && return 0
  printf '%s\n' "$1" >> "$EMITTED" 2>/dev/null || true
}

# Persist the command regardless; only emit when the title actually changed.
if [ "$title" = "$last_title" ]; then
  record_emitted "$title"
  printf '%s\n%s\n' "$command" "$last_title" > "$STATE" 2>/dev/null || true
  exit 0
fi

record_emitted "$title"
printf '%s\n%s\n' "$command" "$title" > "$STATE" 2>/dev/null || true

jq -n --arg ev "$EVENT" --arg t "$title" '{
  hookSpecificOutput: {
    hookEventName: $ev,
    sessionTitle: $t
  }
}'
exit 0
