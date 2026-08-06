#!/bin/bash
# block-repo-edits-use-worktree.sh — PreToolUse hook for Edit, Write, MultiEdit.
#
# Blocks any write whose resolved path lands under {HQ_ROOT}/repos/ unless the
# path is inside a worktree at {HQ_ROOT}/workspace/worktrees/. Nudges the
# agent to spin up a worktree via /personal:worktree before touching a source
# checkout.
#
# Symlinks and `..` are resolved before the prefix check so paths like
# `repos/private/../private/foo` or symlinks into repos/ still trip the
# guard.
#
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || true
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

if [[ "$FILE_PATH" != /* ]]; then
  FILE_PATH="$PROJECT_DIR/$FILE_PATH"
fi

# Resolve symlinks and `..` so dodges don't slip past the prefix check.
# Use python3 realpath-with-strict=False so non-existent target files (Write
# creating a new file) still resolve their parent chain.
if command -v python3 >/dev/null 2>&1; then
  FILE_PATH="$(python3 -c '
import os, sys
p = sys.argv[1]
# Resolve parents that exist; preserve the leaf even if it does not.
parent = os.path.dirname(p) or "/"
leaf = os.path.basename(p)
try:
    parent = os.path.realpath(parent)
except OSError:
    pass
sys.stdout.write(os.path.normpath(os.path.join(parent, leaf)))
' "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")"
  PROJECT_DIR="$(python3 -c 'import os,sys; sys.stdout.write(os.path.realpath(sys.argv[1]))' "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")"
fi

REPOS_DIR="$PROJECT_DIR/repos"
WORKTREES_DIR="$PROJECT_DIR/workspace/worktrees"

# Only concerned with paths under repos/.
case "$FILE_PATH" in
  "$REPOS_DIR"|"$REPOS_DIR"/*) ;;
  *) exit 0 ;;
esac

# Worktrees live under workspace/worktrees/ — those are the intended target,
# allow them. (They can't actually land here after realpath unless someone
# symlinked, but defensively check anyway.)
case "$FILE_PATH" in
  "$WORKTREES_DIR"|"$WORKTREES_DIR"/*) exit 0 ;;
esac

REL="${FILE_PATH#$PROJECT_DIR/}"

cat >&2 <<EOF
BLOCKED: direct edits inside repos/ are not allowed.
  File: $REL

Source checkouts under repos/ should not be edited in place. Spin up a
worktree first so the change lands on a fresh branch under
workspace/worktrees/<repo>/<name>/:

  Use the /personal:worktree skill to create a worktree, then edit there.
EOF
exit 2
