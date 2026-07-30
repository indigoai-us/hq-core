#!/usr/bin/env bash
# PostToolUse hook — emits "JOURNAL ENTRY DUE" reminders at milestone boundaries.
#
# Triggers (any one):
#   - Every 10 successful Edit/Write/MultiEdit tool calls, counted PER SESSION,
#     announced once per threshold crossing (not on every later edit)
#   - Successful `git commit`
#   - Successful test/typecheck/lint run, debounced per session, and only when
#     there has been real edit work since the last journal entry
#
# Reads the PostToolUse JSON from stdin (Claude Code hook contract). Emits nothing
# to stdout unless a journal reminder is due — Claude Code surfaces stdout as
# a system reminder in the next turn. Always exits 0.
#
# Failed tool calls never count as milestones. Claude Code does not dispatch
# PostToolUse for a failed call at all, but the Codex adapter forwards every call
# with `tool_response.exit_code`, so a red test run used to mint a reminder and
# every targeted rerun minted another.
#
# State (all session-keyed, so concurrent tasks never trip each other):
#   workspace/threads/journal/<today>/.tool-count-<session>      edit counter
#   workspace/orchestrator/hook-state/journal-remind-<session>   last announced count
#   workspace/orchestrator/hook-state/journal-test-<session>     test-run debounce
#   workspace/orchestrator/hook-state/journal-seen-<session>     entry count last seen
#
# Suppress with HQ_DISABLED_HOOKS=journal-due (handled by hook-gate.sh wrapper).

set -uo pipefail

HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOURNAL_HELPER="$HQ_ROOT/core/scripts/session-journal.sh"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

# Read stdin JSON (fail-soft if absent or invalid).
stdin_json=""
if [ -t 0 ]; then
  exit 0
fi
stdin_json=$(cat || true)
[ -z "$stdin_json" ] && exit 0

# A failed call is not a milestone.
if hq_hook_tool_failed "$stdin_json"; then
  exit 0
fi

# Extract tool name + tool input command (best-effort).
tool_name=$(printf '%s' "$stdin_json" | hq_json_get tool_name)
tool_cmd=$(printf '%s' "$stdin_json" | hq_json_get tool_input.command)

session_key=$(hq_hook_session_key_from_payload "$stdin_json")
state_dir=$(hq_hook_state_dir "$HQ_ROOT")
remind_file="$state_dir/journal-remind-$session_key"
test_debounce_file="$state_dir/journal-test-$session_key"
seen_file="$state_dir/journal-seen-$session_key"

# Self-heal on a fresh journal entry. `/journal` runs the helper from a plain
# shell that usually cannot know this hook's session key, so it cannot reset a
# session-scoped counter directly. Detect a new entry here instead: if today's
# entry count changed since the last tool call, this session's milestone was
# journaled — clear its counter and its announcement mark.
journal_dir="$("$JOURNAL_HELPER" dir-path 2>/dev/null)"
entries=0
if [ -n "$journal_dir" ] && [ -d "$journal_dir" ]; then
  entries=$(ls "$journal_dir" 2>/dev/null | grep -cE '^[0-9]{3}-.*\.md$')
fi
[ -n "$entries" ] || entries=0
seen=""
[ -f "$seen_file" ] && seen=$(tr -dc '0-9' < "$seen_file" 2>/dev/null)
if [ -n "$seen" ] && [ "$entries" != "$seen" ]; then
  "$JOURNAL_HELPER" tool-counter reset --session "$session_key" 2>/dev/null
  rm -f "$remind_file" "$test_debounce_file" 2>/dev/null || true
fi
printf '%s' "$entries" > "$seen_file" 2>/dev/null || true

THRESHOLD=10
TEST_DEBOUNCE_SECONDS=900
should_remind=0
reason=""

case "$tool_name" in
  Edit|Write|MultiEdit|NotebookEdit)
    "$JOURNAL_HELPER" tool-counter increment --session "$session_key" 2>/dev/null
    n=$("$JOURNAL_HELPER" tool-counter read --session "$session_key" 2>/dev/null)
    [ -n "$n" ] || n=0

    # Highest count already announced for this session. Writing a journal entry
    # resets the counter, so a count below the mark means the mark is stale.
    last=0
    [ -f "$remind_file" ] && last=$(tr -dc '0-9' < "$remind_file" 2>/dev/null)
    [ -n "$last" ] || last=0
    if [ "$n" -lt "$last" ] 2>/dev/null; then
      last=0
    fi

    # Announce on each threshold crossing, once — not on every subsequent edit.
    if [ "$n" -ge "$THRESHOLD" ] && [ "$n" -ge $(( last + THRESHOLD )) ] 2>/dev/null; then
      should_remind=1
      reason="$THRESHOLD edits since last entry"
      printf '%s' "$n" > "$remind_file" 2>/dev/null || true
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

    # A green test run is only a milestone if it certifies work that has not
    # been journaled yet, and only once per debounce window.
    if [ "$should_remind" = "1" ] && [ "$reason" != "git commit" ]; then
      edits=$("$JOURNAL_HELPER" tool-counter read --session "$session_key" 2>/dev/null)
      [ -n "$edits" ] || edits=0
      if [ "$edits" -eq 0 ] 2>/dev/null; then
        should_remind=0
      elif hq_hook_within_window "$test_debounce_file" "$TEST_DEBOUNCE_SECONDS"; then
        should_remind=0
      else
        hq_hook_stamp_now "$test_debounce_file"
      fi
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
