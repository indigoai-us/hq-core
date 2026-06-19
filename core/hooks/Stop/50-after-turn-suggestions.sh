#!/usr/bin/env bash
# Stop hook: emit lightweight "what next?" suggestions after each assistant turn.
#
# Disable options:
#   HQ_AFTER_TURN_SUGGESTIONS=0
#   HQ_DISABLED_HOOKS=after-turn-suggestions
#   touch .claude/state/after-turn-suggestions.disabled
#
# This hook is advisory only. It must never block a session turn.

set -uo pipefail

{
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

  enabled="$(printf '%s' "${HQ_AFTER_TURN_SUGGESTIONS:-1}" | tr '[:upper:]' '[:lower:]')"
  case "$enabled" in
    0|false|off|no|disabled) exit 0 ;;
  esac

  disabled_hooks=",${HQ_DISABLED_HOOKS:-},"
  disabled_hooks="$(printf '%s' "$disabled_hooks" | tr -d '[:space:]')"
  case "$disabled_hooks" in
    *,after-turn-suggestions,*) exit 0 ;;
  esac

  [ -f "$REPO_ROOT/.claude/state/after-turn-suggestions.disabled" ] && exit 0

  INPUT="$(cat 2>/dev/null || echo '{}')"
  TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
  SHARE_HELPER="$REPO_ROOT/core/scripts/share-suggestion-state.sh"

  if [ -n "$SESSION_ID" ] && [ -f "$SHARE_HELPER" ]; then
    pending_share="$("$SHARE_HELPER" peek "$SESSION_ID" || true)"
    [ -n "$pending_share" ] && exit 0
  fi

  LAST_TEXT=""
  if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
    LAST_ASSISTANT="$(awk '/"type":"assistant"/ { last=$0 } END { print last }' "$TRANSCRIPT_PATH" 2>/dev/null || true)"
    if [ -n "$LAST_ASSISTANT" ]; then
      LAST_TEXT="$(printf '%s' "$LAST_ASSISTANT" | jq -r '
        .message.content as $c
        | if ($c | type) == "array" then
            [$c[] | select(.type == "text") | .text] | join("\n")
          elif ($c | type) == "string" then
            $c
          else "" end
      ' 2>/dev/null || true)"
    fi
  fi

  lower_text="$(printf '%s' "$LAST_TEXT" | tr '[:upper:]' '[:lower:]')"

  ACTIVE_PROJECT=""
  JOURNAL_POINTER="$REPO_ROOT/.claude/state/active-journal"
  if [ -f "$JOURNAL_POINTER" ]; then
    journal_path="$(cat "$JOURNAL_POINTER" 2>/dev/null | tr -d '\n' || true)"
    if [ -n "$journal_path" ] && [ -r "$journal_path" ]; then
      ACTIVE_PROJECT="$(awk '/^project: / { sub(/^project: /, ""); print; exit }' "$journal_path" 2>/dev/null || true)"
    fi
  fi

  project_name=""
  if [ -n "$ACTIVE_PROJECT" ]; then
    project_name="$(basename "$ACTIVE_PROJECT")"
  fi

  suggestions=""
  suggestion_count=0

  add_suggestion() {
    [ "$suggestion_count" -ge 4 ] && return 0
    case "$suggestions" in
      *"$1"*) return 0 ;;
    esac
    suggestions="${suggestions}- $1
"
    suggestion_count=$((suggestion_count + 1))
  }

  project_dir=""
  if [ -n "$ACTIVE_PROJECT" ]; then
    case "$ACTIVE_PROJECT" in
      /*) project_dir="$ACTIVE_PROJECT" ;;
      *) project_dir="$REPO_ROOT/$ACTIVE_PROJECT" ;;
    esac
  fi

  if [ -n "$project_dir" ] && [ -f "$project_dir/prd.json" ]; then
    incomplete_count="$(jq '[.userStories[]? | select(.passes != true)] | length' "$project_dir/prd.json" 2>/dev/null || echo 0)"
    next_story="$(jq -r '.userStories[]? | select(.passes != true) | .id' "$project_dir/prd.json" 2>/dev/null | head -1)"
    if [ "${incomplete_count:-0}" -gt 0 ] 2>/dev/null && [ -n "$next_story" ]; then
      add_suggestion "Run the next story: \`/execute-task ${project_name}/${next_story}\` or \`/run-project ${project_name}\`."
    else
      add_suggestion "If this project shipped, run \`/document-release\` or a quick \`/retro\` before moving on."
    fi
  elif [ -n "$project_dir" ] && [ -f "$project_dir/brainstorm.md" ]; then
    add_suggestion "Promote this brainstorm to a PRD when ready: \`/prd ${project_name}\`."
    add_suggestion "Tighten the open questions in \`${ACTIVE_PROJECT}/brainstorm.md\` before planning."
  fi

  if printf '%s' "$lower_text" | grep -qE 'brainstorm.*created|brainstorm:|recommendation: option'; then
    add_suggestion "Choose the recommendation path, then promote it with \`/prd\`."
  fi

  if printf '%s' "$lower_text" | grep -qE 'project .*(created|ready)|prd\.json|user stories'; then
    add_suggestion "Start execution in a fresh session with \`/run-project ${project_name:-<project>}\`."
    add_suggestion "Review the plan before building with \`/review-plan ${project_name:-<project>}\`."
  fi

  if printf '%s' "$lower_text" | grep -qE 'task complete|story complete|passes: true|all tests pass'; then
    add_suggestion "Checkpoint the completed step with \`/checkpoint\` if the session should continue."
    add_suggestion "Pick the next incomplete story or run \`/review\` if this is ready to land."
  fi

  if printf '%s' "$lower_text" | grep -qE 'handoff ready|to continue in a fresh session'; then
    add_suggestion "Open a fresh session and run \`/startwork\` to resume from the handoff."
  fi

  if printf '%s' "$lower_text" | grep -qE 'blocked|failing|failed|error|unable|could not|couldn.t'; then
    add_suggestion "If this is a real blocker, switch to \`/investigate\` and capture the failing evidence."
  fi

  if [ "$suggestion_count" -eq 0 ]; then
    if [ -n "$project_name" ]; then
      add_suggestion "Continue \`${project_name}\` by choosing the next unchecked item or promoting the current artifact."
      add_suggestion "If context is getting heavy, run \`/checkpoint\` before the next step."
    else
      add_suggestion "Run \`/startwork\` to choose the next company, project, repo, or task."
      add_suggestion "Capture a new idea with \`/brainstorm\` if the next step is still fuzzy."
    fi
  fi

  [ "$suggestion_count" -eq 0 ] && exit 0

  first_session_note=""
  if [ -n "$SESSION_ID" ]; then
    state_dir="$REPO_ROOT/workspace/.after-turn-suggestions"
    mkdir -p "$state_dir" 2>/dev/null || true
    seen_file="$state_dir/$SESSION_ID"
    if [ ! -e "$seen_file" ]; then
      first_session_note="Turn off these nudges with \`HQ_AFTER_TURN_SUGGESTIONS=0\`, \`HQ_DISABLED_HOOKS=after-turn-suggestions\`, or \`.claude/state/after-turn-suggestions.disabled\`."
      touch "$seen_file" 2>/dev/null || true
    fi
  fi

  printf '<hq-suggestions>\n'
  printf 'Suggested next moves:\n'
  printf '%s' "$suggestions"
  if [ -n "$first_session_note" ]; then
    printf '%s\n' "$first_session_note"
  fi
  printf '</hq-suggestions>\n'
} 2>/dev/null || true

exit 0
