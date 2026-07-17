#!/bin/bash
# hq-core: public
# hq-autocommit.sh — silent local HQ autosave for non-repo edits.
#
# Runs after Edit/Write/MultiEdit-shaped changes. It commits only the file path
# touched by the just-finished tool call, skips repos/ and nested git repos, and
# emits no user-facing output. Specific repo work keeps normal commit discipline.

set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"

if [[ "${HQ_AUTOCOMMIT:-1}" == "0" ]]; then
  exit 0
fi

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL_NAME" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

if [[ ! -d "$HQ_ROOT/.git" || ! -f "$HQ_ROOT/core/core.yaml" ]]; then
  exit 0
fi

FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

if [[ "$FILE_PATH" != /* ]]; then
  FILE_PATH="$HQ_ROOT/$FILE_PATH"
fi

DIR_PATH="$FILE_PATH"
if [[ ! -d "$DIR_PATH" ]]; then
  DIR_PATH="$(dirname "$FILE_PATH")"
fi

PATH_TOP="$(git -C "$DIR_PATH" rev-parse --show-toplevel 2>/dev/null || true)"
HQ_TOP="$(git -C "$HQ_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$PATH_TOP" || -z "$HQ_TOP" || "$PATH_TOP" != "$HQ_TOP" ]]; then
  exit 0
fi

if [[ -d "$FILE_PATH" ]]; then
  REL_PATH="$(git -C "$FILE_PATH" rev-parse --show-prefix 2>/dev/null || true)"
  REL_PATH="${REL_PATH%/}"
else
  PREFIX="$(git -C "$DIR_PATH" rev-parse --show-prefix 2>/dev/null || true)"
  REL_PATH="${PREFIX}$(basename "$FILE_PATH")"
fi

if [[ -z "$REL_PATH" ]]; then
  exit 0
fi

case "$REL_PATH" in
  .git/*|repos/*|node_modules/*|.next/*|.vercel/*|*.tmp|*.log)
    exit 0
    ;;
  workspace/worktrees/*|.claude/worktrees/*)
    # Live project worktrees are their own linked git repos with a moving HEAD.
    # Never sweep one into the HQ root as an embedded gitlink — that leaves the
    # tree permanently dirty and blocks /handoff + session archiving.
    # (feedback_2ada615f)
    exit 0
    ;;
  companies/*/knowledge|companies/*/knowledge/*)
    # Company knowledge can be an embedded or symlinked repo. Let its own repo
    # discipline decide when to commit.
    exit 0
    ;;
esac

STATUS="$(git -C "$HQ_ROOT" status --porcelain -- "$REL_PATH" 2>/dev/null || true)"
if [[ -z "$STATUS" ]]; then
  exit 0
fi

if [[ -n "$(git -C "$HQ_ROOT" diff --cached --name-only 2>/dev/null)" ]]; then
  exit 0
fi

LOG_FILE="/tmp/hq-autocommit.log"
LOCK_DIR="/tmp/hq-autocommit.lock"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

{
  git -C "$HQ_ROOT" add -- "$REL_PATH" || exit 0

  # Refuse to autosave an embedded git repo (gitlink, mode 160000). A directory
  # add that reaches a nested worktree/repo would otherwise stage it into the HQ
  # root, leaving the tree permanently dirty and blocking /handoff + archiving.
  # Unstage and bail rather than commit a moving gitlink. (feedback_2ada615f)
  if git -C "$HQ_ROOT" ls-files --stage -- "$REL_PATH" 2>/dev/null \
       | awk '$1 == "160000" { hit = 1 } END { exit hit ? 0 : 1 }'; then
    git -C "$HQ_ROOT" reset -q -- "$REL_PATH" 2>/dev/null || true
    exit 0
  fi

  git -C "$HQ_ROOT" diff --cached --quiet -- "$REL_PATH" && exit 0

  msg_path="$REL_PATH"
  if [[ ${#msg_path} -gt 72 ]]; then
    msg_path="${msg_path:0:69}..."
  fi

  git -C "$HQ_ROOT" commit --no-verify -m "autosave(hq): ${msg_path}"
} >>"$LOG_FILE" 2>&1 || true

exit 0
