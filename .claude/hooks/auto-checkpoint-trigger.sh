#!/bin/bash
# PostToolUse hook: detect checkpoint-worthy events and nudge Claude to write a lightweight auto-checkpoint.
# Fires after Bash (git commit, push, PR, deploy, test, publish, API mutation),
# Edit (any file edit outside threads/), and Write (report/draft generation) tool calls.
# Fast path (<50ms) for non-matching calls. Debounce: 5min for most triggers,
# git commit/push always fire immediately.

set -euo pipefail

HQ="${HOME}/Documents/HQ"
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

should_checkpoint=false
skip_debounce=false
trigger=""

case "$TOOL_NAME" in
  Bash)
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    # Always checkpoint (bypass debounce)
    if echo "$CMD" | grep -qE 'git commit(\s|$)'; then
      should_checkpoint=true
      skip_debounce=true
      trigger="git-commit"
    elif echo "$CMD" | grep -qE 'git push(\s|$)'; then
      should_checkpoint=true
      skip_debounce=true
      trigger="git-push"
    # Debounced triggers
    elif echo "$CMD" | grep -qE 'gh pr (create|merge)'; then
      should_checkpoint=true
      trigger="pr-operation"
    elif echo "$CMD" | grep -qE 'vercel (deploy|--prod)'; then
      should_checkpoint=true
      trigger="deployment"
    elif echo "$CMD" | grep -qE '(npm|bun) publish'; then
      should_checkpoint=true
      trigger="package-publish"
    elif echo "$CMD" | grep -qE '(bun run test|npm test|bun test)(\s|$)'; then
      should_checkpoint=true
      trigger="test-run"
    elif echo "$CMD" | grep -qE 'curl -X (POST|PUT|DELETE)'; then
      should_checkpoint=true
      trigger="api-mutation"
    fi
    ;;
  Edit)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    # Exclude workspace/threads/ to prevent checkpoint-triggers-checkpoint loops
    if echo "$FILE_PATH" | grep -qE 'workspace/threads/'; then
      should_checkpoint=false
    else
      should_checkpoint=true
      trigger="file-edit"
    fi
    ;;
  Write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    # Exclude workspace/threads/ to prevent checkpoint-triggers-checkpoint loops
    if echo "$FILE_PATH" | grep -qE 'workspace/threads/'; then
      should_checkpoint=false
    # Match report/social-draft/company-data generation
    elif echo "$FILE_PATH" | grep -qE '(workspace/reports/|workspace/social-drafts/|companies/.*/data/)'; then
      should_checkpoint=true
      trigger="file-generation"
    fi
    ;;
esac

if [ "$should_checkpoint" = false ]; then
  exit 0
fi

# Debounce check: suppress if last nudge was <300s ago (unless skip_debounce)
DEBOUNCE_FILE="/tmp/hq-checkpoint-last-${PPID}"
DEBOUNCE_SECONDS=300

if [ "$skip_debounce" = false ] && [ -f "$DEBOUNCE_FILE" ]; then
  LAST_NUDGE=$(cat "$DEBOUNCE_FILE" 2>/dev/null || echo "0")
  NOW=$(date +%s)
  ELAPSED=$(( NOW - LAST_NUDGE ))
  if [ "$ELAPSED" -lt "$DEBOUNCE_SECONDS" ]; then
    exit 0
  fi
fi

# Capture current git state
cd "$HQ"
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
DIRTY_COUNT=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")

# Update debounce timestamp
date +%s > "$DEBOUNCE_FILE"

# Build the nudge message
cat <<EOF
AUTO-CHECKPOINT REQUIRED (trigger: ${trigger}).

Write a lightweight auto-checkpoint thread NOW:
  File: workspace/threads/T-${TIMESTAMP}-auto-{slug}.json
  (Replace {slug} with 2-3 word summary of recent work)

Include ONLY:
  thread_id, version: 1, type: "auto-checkpoint", created_at, updated_at,
  workspace_root, cwd,
  git: { branch: "${GIT_BRANCH}", current_commit: "${GIT_SHA}", dirty: $([ "$DIRTY_COUNT" -gt 0 ] && echo "true" || echo "false") },
  conversation_summary (1 sentence), files_touched (from this session),
  metadata: { title: "Auto: ...", tags: ["auto-checkpoint"], trigger: "${trigger}" }

Do NOT: rebuild INDEX files, update recent.md, run qmd update, write legacy checkpoint.
Keep it fast — just write the JSON file and continue working.
EOF
