#!/usr/bin/env bash
# worktree-sweep.sh - read-only report of dirty or unpushed git worktrees.
#
# Usage: worktree-sweep.sh [--root <hq-root>]
#
# Scans <root>/workspace/worktrees/*/* (and one level deeper for repo-named
# groups) and prints one line per worktree that has uncommitted changes or
# commits not on its upstream:
#   <path>\t<branch>\tdirty=<n>\tahead=<n>
# Prints nothing when every worktree is clean and pushed. Never modifies a
# worktree. Exists so a multi-worktree sweep does not need shell-variable
# paths in the agent's Bash calls (the scope guard blocks those).
set -euo pipefail

ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    *) echo "worktree-sweep: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/workspace/worktrees"
[ -d "$BASE" ] || exit 0

for dir in "$BASE"/* "$BASE"/*/*; do
  [ -e "$dir/.git" ] || continue
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  dirty="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  ahead=0
  if git -C "$dir" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    ahead="$(git -C "$dir" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)"
  elif [ "$branch" != "HEAD" ] && [ "$branch" != "?" ]; then
    ahead="$(git -C "$dir" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)"
  fi
  if [ "$dirty" != "0" ] || [ "$ahead" != "0" ]; then
    printf '%s\t%s\tdirty=%s\tahead=%s\n' "$dir" "$branch" "$dirty" "$ahead"
  fi
done
