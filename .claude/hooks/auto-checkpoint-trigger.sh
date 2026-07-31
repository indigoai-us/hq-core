#!/bin/bash
# PostToolUse hook: detect checkpoint-worthy events and suggest a lightweight auto-checkpoint.
# Fires after Bash (git commit, push, PR, deploy, test, publish, API mutation),
# sustained Edit activity, and Write (report/draft generation) tool calls.
# Fast path (<50ms) for non-matching calls.
#
# This hook is ADVISORY. Mandatory checkpoints belong to the context-threshold
# and pre-compaction hooks (context-warning-50.sh, auto-checkpoint-precompact.sh),
# which still emit "AUTO-CHECKPOINT REQUIRED". A per-edit tool signal is not
# worth interrupting work for, so this one emits "AUTO-CHECKPOINT SUGGESTED".
#
# Noise controls (all keyed by SESSION, never by $PPID — tool and hook processes
# do not share a parent PID in every host, so a PID-keyed debounce silently
# never applies and every edit re-fires):
#   - Debounce: 5 min per session; git commit/push bypass it.
#   - Edits do not checkpoint one-by-one. A file-edit checkpoint needs both an
#     edit threshold (10 edits since the last one) AND the elapsed debounce.
#   - Failed tool calls are ignored.
#
# State: workspace/orchestrator/hook-state/checkpoint-{last,edits}-<session>

set -euo pipefail

# Resolve the active HQ root regardless of install path or session cwd:
# CLAUDE_PROJECT_DIR (set by Claude Code) → HQ_ROOT env → the hook's own
# location (always <HQ>/.claude/hooks/, matching master-hook.sh/reindex.sh) →
# legacy default. Never hardcode ~/Documents/HQ as the sole source.
HQ="${CLAUDE_PROJECT_DIR:-${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)}}"
HQ="${HQ:-${HOME}/Documents/HQ}"
INPUT=$(cat)

. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)/core/scripts/hook-lib.sh"

# A failed tool call is not a checkpoint-worthy event.
if hq_hook_tool_failed "$INPUT"; then
  exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
SESSION_KEY=$(hq_hook_session_key_from_payload "$INPUT")
STATE_DIR=$(hq_hook_state_dir "$HQ")
DEBOUNCE_FILE="$STATE_DIR/checkpoint-last-$SESSION_KEY"
EDITS_FILE="$STATE_DIR/checkpoint-edits-$SESSION_KEY"

DEBOUNCE_SECONDS=300
EDIT_THRESHOLD=10

should_checkpoint=false
skip_debounce=false
trigger=""
FILE_PATH=""

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
  Edit|MultiEdit)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    # Exclude workspace/threads/ + companies/*/workspace/ mirror writes to prevent checkpoint loops
    if echo "$FILE_PATH" | grep -qE 'workspace/threads/|companies/.*/workspace/(sessions/|index\.jsonl|\.gitignore)'; then
      should_checkpoint=false
    else
      # Sustained editing is the signal, not any single edit. Count first; only
      # cross into checkpoint territory once the session has done real work.
      edits=0
      [ -f "$EDITS_FILE" ] && edits=$(tr -dc '0-9' < "$EDITS_FILE" 2>/dev/null || echo 0)
      [ -n "$edits" ] || edits=0
      edits=$(( edits + 1 ))
      printf '%s' "$edits" > "$EDITS_FILE" 2>/dev/null || true
      if [ "$edits" -ge "$EDIT_THRESHOLD" ]; then
        should_checkpoint=true
        trigger="sustained-edits"
      fi
    fi
    ;;
  Write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    # Exclude workspace/threads/ + companies/*/workspace/ mirror writes to prevent checkpoint loops
    if echo "$FILE_PATH" | grep -qE 'workspace/threads/|companies/.*/workspace/(sessions/|index\.jsonl|\.gitignore)'; then
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

# Debounce check: suppress if the last nudge for THIS session was <300s ago.
if [ "$skip_debounce" = false ] && hq_hook_within_window "$DEBOUNCE_FILE" "$DEBOUNCE_SECONDS"; then
  exit 0
fi

# Capture git state for the repository actually being worked in. Resolving from
# $HQ recorded HQ root's branch and commit even when the edits landed in an app
# worktree, which made the checkpoint's git metadata actively misleading.
GIT_DIR_HINT=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$GIT_DIR_HINT" ] && [ -n "$FILE_PATH" ]; then
  GIT_DIR_HINT=$(dirname "$FILE_PATH")
fi
[ -z "$GIT_DIR_HINT" ] && GIT_DIR_HINT="$PWD"
[ -d "$GIT_DIR_HINT" ] || GIT_DIR_HINT="$HQ"

REPO_DIR=$(git -C "$GIT_DIR_HINT" rev-parse --show-toplevel 2>/dev/null || echo "$HQ")
GIT_SHA=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
# pipefail would abort the hook if `git status` fails (not a repo, no HEAD yet),
# so capture the porcelain output first and count it separately.
GIT_PORCELAIN=$(git -C "$REPO_DIR" status --porcelain 2>/dev/null || true)
DIRTY_COUNT=$(printf '%s' "$GIT_PORCELAIN" | grep -c . || true)
[ -n "$DIRTY_COUNT" ] || DIRTY_COUNT=0
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")

# Update debounce timestamp and clear the edit budget this nudge consumed.
hq_hook_stamp_now "$DEBOUNCE_FILE"
printf '0' > "$EDITS_FILE" 2>/dev/null || true

# Build the nudge message
cat <<EOF
AUTO-CHECKPOINT SUGGESTED (trigger: ${trigger}).

Write a lightweight auto-checkpoint thread when you reach a natural pause:
  File: workspace/threads/T-${TIMESTAMP}-auto-{slug}.json
  (Replace {slug} with 2-3 word summary of recent work)

Include ONLY:
  thread_id, version: 1, type: "auto-checkpoint", created_at, updated_at,
  workspace_root, cwd,
  git: { branch: "${GIT_BRANCH}", current_commit: "${GIT_SHA}", dirty: $([ "$DIRTY_COUNT" -gt 0 ] && echo "true" || echo "false") },
  conversation_summary (1 sentence), files_touched (from this session),
  metadata: { title: "Auto: ...", tags: ["auto-checkpoint"], trigger: "${trigger}" }

Do NOT: rebuild INDEX files, update recent.md, run qmd update, write legacy checkpoint.
Keep it fast — just write the JSON file and continue working. Do not interrupt
in-flight work for this; mandatory checkpoints are announced as AUTO-CHECKPOINT
REQUIRED by the context-threshold and pre-compaction hooks.
EOF
