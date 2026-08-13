#!/bin/bash
# block-repo-edits-use-worktree.sh — PreToolUse hook for Edit, Write, MultiEdit.
#
# Blocks any write whose resolved path lands under {HQ_ROOT}/repos/ unless the
# path is inside a worktree at {HQ_ROOT}/workspace/worktrees/. Nudges the
# agent to spin up a worktree via /personal:worktree before touching a source
# checkout.
#
# THE ONE SANCTIONED WORKTREE LOCATION IS {HQ_ROOT}/workspace/worktrees/.
# There is deliberately no exemption for worktrees created elsewhere — not for
# siblings of a checkout under repos/, not for knowledge repos, not behind an
# env-var escape hatch. Every such exemption is a hole in the guard, and the
# structural checks that would police them (is this really a worktree? is this
# really a knowledge repo?) are exactly the kind of thing that decays. Anything
# that needs to write under repos/ should instead create its worktree in the
# sanctioned location; core/scripts/worktree.sh and the run-project orchestrator
# both do.
#
# Symlinks and `..` are resolved before the prefix check so paths like
# `repos/private/../private/foo` or symlinks into repos/ still trip the
# guard. An invalid legacy knowledge tree symlinked in from repos/ therefore
# also lands here intentionally. The block message below requires migration.
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

# Absolute but NOT yet symlink-resolved — used only to phrase the diagnostic, so
# a write that arrived through a legacy knowledge symlink can be told to migrate
# instead of being told, unhelpfully, about a repos/ path it never named.
RAW_PATH="$FILE_PATH"
RAW_PROJECT_DIR="$PROJECT_DIR"

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

# A write that arrived through a legacy knowledge symlink gets a migration
# diagnostic rather than the code-worktree route.
KNOWLEDGE_WRITE=false
for KNOWN_BASE in "$RAW_PROJECT_DIR" "$PROJECT_DIR"; do
  [[ -n "$KNOWN_BASE" ]] || continue
  case "$RAW_PATH" in
    "$KNOWN_BASE"/companies/*/knowledge/*|"$KNOWN_BASE"/personal/knowledge/*|"$KNOWN_BASE"/core/knowledge/*)
      KNOWLEDGE_WRITE=true ;;
  esac
done

if [[ "$KNOWLEDGE_WRITE" == true ]]; then
  RAW_REL="${RAW_PATH#$RAW_PROJECT_DIR/}"
  cat >&2 <<EOF
BLOCKED: direct edits inside repos/ are not allowed.
  File: $RAW_REL
  Resolves to: $REL

This is an invalid legacy knowledge symlink. Knowledge repositories must be
real directories at their canonical path, with git initialized there when
separate history is needed. Never write through this link or bypass the guard.

Run \`hq reindex\` to migrate automatically: it pulls the legacy repo, copies
its content (and git history) inline at "$RAW_REL", and removes the fully
migrated legacy repo. Or materialize the content by hand, preserving its git
history there if needed. Either way, verify both:

  test -d "$RAW_REL"
  ! test -L "$RAW_REL"
EOF
  exit 2
fi

cat >&2 <<EOF
BLOCKED: direct edits inside repos/ are not allowed.
  File: $REL

Source checkouts under repos/ should not be edited in place. Every edit belongs
in a worktree, and the ONE sanctioned location for a worktree is:

  workspace/worktrees/<repo>/<name>/

Nothing under repos/ is a valid edit target, including a worktree someone
created there — create it in workspace/worktrees/ instead. Cut one with:

  bash core/scripts/worktree.sh --name <kebab-slug> --source <repo-path>

or use the /personal:worktree skill, then edit inside the path it prints.
EOF
exit 2
