#!/usr/bin/env bash
# Create a git worktree under {HQ_ROOT}/workspace/worktrees/{repo}/{name}/ on a
# fresh branch pointing at origin/{default-branch}. The source repo's working
# tree and local branch refs are left untouched.
#
# Usage:
#   worktree.sh --name <slug> [--source <repo-path>] [--branch <new-branch>]
#               [--base <branch-or-ref>] [--no-pull]

set -euo pipefail

NAME=""
SOURCE=""
BRANCH=""
BASE=""
NO_PULL=0

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,8p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)    NAME="${2:-}"; shift 2 ;;
    --source)  SOURCE="${2:-}"; shift 2 ;;
    --branch)  BRANCH="${2:-}"; shift 2 ;;
    --base)    BASE="${2:-}"; shift 2 ;;
    --no-pull) NO_PULL=1; shift ;;
    -h|--help) usage 0 ;;
    *)         echo "unknown arg: $1" >&2; usage 2 ;;
  esac
done

[ -n "$NAME" ] || die "--name is required (kebab-case slug, e.g. 'fix-login-bug')"

# Validate name: kebab-case-ish, no slashes, no spaces
case "$NAME" in
  */*|*" "*|"")  die "invalid --name '$NAME': no slashes or spaces; use kebab-case" ;;
esac

# --- resolve source repo -----------------------------------------------------
if [ -z "$SOURCE" ]; then
  SOURCE="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$SOURCE" ] || die "not inside a git repo and --source not given"
[ -d "$SOURCE/.git" ] || [ -f "$SOURCE/.git" ] || die "$SOURCE is not a git repo"
SOURCE="$(cd "$SOURCE" && pwd)"
REPO_BASENAME="$(basename "$SOURCE")"

# --- resolve HQ root ---------------------------------------------------------
HQ_ROOT="${HQ_HOME:-}"
if [ -z "$HQ_ROOT" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  # core/scripts/worktree.sh -> ../.. = HQ root
  HQ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
[ -d "$HQ_ROOT/workspace" ] || die "HQ_ROOT=$HQ_ROOT has no workspace/ directory"

# --- resolve default branch --------------------------------------------------
HAS_ORIGIN=0
if git -C "$SOURCE" remote get-url origin >/dev/null 2>&1; then
  HAS_ORIGIN=1
fi

if [ -z "$BASE" ]; then
  if [ "$HAS_ORIGIN" -eq 1 ]; then
    BASE="$(git -C "$SOURCE" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
  fi
  if [ -z "$BASE" ]; then
    if git -C "$SOURCE" show-ref --verify --quiet refs/heads/main; then
      BASE="main"
    elif git -C "$SOURCE" show-ref --verify --quiet refs/heads/master; then
      BASE="master"
    else
      die "cannot determine default branch; pass --base <branch>"
    fi
  fi
fi

# --- fetch (unless --no-pull) ------------------------------------------------
if [ "$NO_PULL" -eq 0 ] && [ "$HAS_ORIGIN" -eq 1 ]; then
  echo "→ fetching origin/$BASE in $SOURCE"
  git -C "$SOURCE" fetch origin "$BASE" \
    || die "git fetch origin $BASE failed; rerun with --no-pull to skip, or fix network/auth"
elif [ "$NO_PULL" -eq 0 ] && [ "$HAS_ORIGIN" -eq 0 ]; then
  echo "⚠ no 'origin' remote on $SOURCE — skipping fetch, basing off local $BASE"
fi

# --- compute branch + paths --------------------------------------------------
BRANCH="${BRANCH:-wt/$NAME}"

# Pick the base ref: prefer origin/$BASE (post-fetch) if it exists, else local $BASE
BASE_REF="$BASE"
if [ "$HAS_ORIGIN" -eq 1 ] && git -C "$SOURCE" rev-parse --verify --quiet "origin/$BASE" >/dev/null; then
  BASE_REF="origin/$BASE"
fi

TARGET_PARENT="$HQ_ROOT/workspace/worktrees/$REPO_BASENAME"
TARGET="$TARGET_PARENT/$NAME"

if [ -e "$TARGET" ]; then
  die "$TARGET already exists. Pick a different --name, or remove it first:
  git -C $SOURCE worktree remove $TARGET"
fi

# Check branch doesn't already exist
if git -C "$SOURCE" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  die "branch '$BRANCH' already exists in $SOURCE. Pass --branch <other-name>, or delete:
  git -C $SOURCE branch -D $BRANCH"
fi

mkdir -p "$TARGET_PARENT"

# --- create the worktree -----------------------------------------------------
echo "→ creating worktree $TARGET on branch $BRANCH from $BASE_REF"
git -C "$SOURCE" worktree add "$TARGET" -b "$BRANCH" "$BASE_REF"

SHORT_SHA="$(git -C "$TARGET" rev-parse --short HEAD)"

cat <<EOF

✓ worktree ready
  path:   $TARGET
  branch: $BRANCH
  base:   $BASE_REF ($SHORT_SHA)
  source: $SOURCE

Main checkout untouched — working tree, local '$BASE' ref, and stash are unchanged.

Cleanup when done:
  git -C $SOURCE worktree remove $TARGET
  git -C $SOURCE branch -D $BRANCH   # optional, drops the branch ref
EOF
