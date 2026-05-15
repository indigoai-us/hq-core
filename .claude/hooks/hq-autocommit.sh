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

if command -v python3 >/dev/null 2>&1; then
  FILE_PATH="$(python3 -c 'import os.path,sys; sys.stdout.write(os.path.realpath(sys.argv[1]))' "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")"
  HQ_ROOT="$(python3 -c 'import os.path,sys; sys.stdout.write(os.path.realpath(sys.argv[1]))' "$HQ_ROOT" 2>/dev/null || echo "$HQ_ROOT")"
fi

case "$FILE_PATH" in
  "$HQ_ROOT"/*) ;;
  *) exit 0 ;;
esac

REL_PATH="${FILE_PATH#$HQ_ROOT/}"
case "$REL_PATH" in
  .git/*|repos/*|node_modules/*|.next/*|.vercel/*|*.tmp|*.log)
    exit 0
    ;;
  companies/*/knowledge|companies/*/knowledge/*)
    # Company knowledge can be an embedded or symlinked repo. Let its own repo
    # discipline decide when to commit.
    exit 0
    ;;
esac

DIR_PATH="$FILE_PATH"
if [[ ! -d "$DIR_PATH" ]]; then
  DIR_PATH="$(dirname "$FILE_PATH")"
fi

PATH_TOP="$(git -C "$DIR_PATH" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$PATH_TOP" && "$PATH_TOP" != "$HQ_ROOT" ]]; then
  exit 0
fi

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
  git -C "$HQ_ROOT" add -- "$REL_PATH" &&
  git -C "$HQ_ROOT" diff --cached --quiet -- "$REL_PATH" && exit 0

  msg_path="$REL_PATH"
  if [[ ${#msg_path} -gt 72 ]]; then
    msg_path="${msg_path:0:69}..."
  fi

  git -C "$HQ_ROOT" commit --no-verify -m "autosave(hq): ${msg_path}"
} >>"$LOG_FILE" 2>&1 || true

exit 0
