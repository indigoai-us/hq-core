#!/usr/bin/env bash
# hq-core: public
#
# worktree-preserve.sh — the one sanctioned way to commit (and optionally push)
# a dirty linked git worktree before it is removed.
#
#   worktree-preserve.sh <worktree-path> [--push] [--dry-run]
#                        [--allow-large "<reason>"] [--root <hq-root>]
#
# Why this exists: on 2026-11-05 an ad hoc purge script ran `git add -A`,
# `git commit --no-verify` and `git push` on every dirty worktree. One worktree
# held a copy of the whole HQ root; 161,628 files went to a private GitHub
# repo. This script replaces that pattern. Every guard below is a hard stop:
#
#   1. The worktree's main repo is never the HQ root (HQ never pushes).
#   2. Only linked worktrees (not a repo's main checkout).
#   3. Change count stays under HQ_PRESERVE_MAX_FILES (default 2000) and
#      HQ_PRESERVE_MAX_BYTES (default 200 MB) unless --allow-large "<reason>".
#   4. No HQ-root marker path among the changes
#      (core/settings/worktree-preserve-denylist.txt, via
#      core/scripts/lib/hq-root-markers.sh).
#   5. The staged set passes the commit secret scan
#      (commit-secret-scan.sh gate). Never --no-verify; the repo's own hooks run.
#   6. The commit lands on the worktree's own branch, or on a new
#      wip/<slug>-<date> branch when HEAD is detached or on main/master, so
#      the shared local main ref is never moved. --push pushes that branch.
#
# Output: one line  <ACTION>\t<worktree>\t<detail>  with ACTION one of
# CLEAN, KEPT, COMMITTED, PUSHED, DRY-RUN. A ledger row is appended to
# <hq-root>/workspace/reports/worktree-preserve-<date>.md (HQ_PRESERVE_LEDGER
# overrides the path; "none" turns it off).
#
# Exit: 0 CLEAN/COMMITTED/PUSHED/DRY-RUN, 1 KEPT (nothing committed), 2 usage.
# Never removes the worktree; the caller does that after a 0 exit.
#
# Bash 3.2-safe, no python/node.

set -u

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
MAX_FILES="${HQ_PRESERVE_MAX_FILES:-2000}"
MAX_BYTES="${HQ_PRESERVE_MAX_BYTES:-209715200}"
WT=""; PUSH=0; DRY=0; ALLOW_LARGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH=1 ;;
    --dry-run) DRY=1 ;;
    --allow-large) ALLOW_LARGE="${2:-}"; [ -n "$ALLOW_LARGE" ] || { echo "worktree-preserve: --allow-large needs a reason" >&2; exit 2; }; shift ;;
    --root) HQ_ROOT="${2:-}"; shift ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "worktree-preserve: unknown option $1" >&2; exit 2 ;;
    *) [ -z "$WT" ] || { echo "worktree-preserve: one worktree path only" >&2; exit 2; }; WT="$1" ;;
  esac
  shift
done
[ -n "$WT" ] || { echo "usage: worktree-preserve.sh <worktree-path> [--push] [--dry-run] [--allow-large <reason>]" >&2; exit 2; }
[ -d "$WT" ] || { echo "worktree-preserve: not a directory: $WT" >&2; exit 2; }
WT="$(cd "$WT" && pwd -P)"
NAME="$(basename "$WT")"
DATE="$(date -u +%Y-%m-%d)"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SLUG="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//; s/-*$//')"
[ -n "$SLUG" ] || SLUG="worktree"

# Git hooks export these; never let them redirect our git calls.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX

# shellcheck source=lib/hq-root-markers.sh
. "$HQ_ROOT/core/scripts/lib/hq-root-markers.sh"

LEDGER="${HQ_PRESERVE_LEDGER:-$HQ_ROOT/workspace/reports/worktree-preserve-$DATE.md}"
ledger() { # action branch sha files note
  [ "$LEDGER" = "none" ] && return 0
  mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || return 0
  if [ ! -f "$LEDGER" ]; then
    printf '# Worktree preserve ledger %s\n\nWritten by core/scripts/worktree-preserve.sh.\n\n| time (UTC) | worktree | action | branch | sha | files | note |\n|---|---|---|---|---|---|---|\n' "$DATE" >"$LEDGER"
  fi
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$STAMP" "$WT" "$1" "$2" "$3" "$4" "$5" >>"$LEDGER"
}
say() { printf '%s\t%s\t%s\n' "$1" "$WT" "$2"; }
kept() { # reason
  ledger KEPT "${BRANCH:-?}" "${HEAD_SHA:-?}" "${N_FILES:-?}" "$1"
  say KEPT "$1"
  exit 1
}

# ---- 1-2: where are we
TOP="$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null)" || { say KEPT "not a git work tree"; exit 1; }
TOP="$(cd "$TOP" && pwd -P)"
[ "$TOP" = "$WT" ] || { say KEPT "not a worktree root (top level is $TOP)"; exit 1; }
GIT_DIR_P="$(cd "$(git -C "$WT" rev-parse --git-dir)" && pwd -P)"
COMMON_P="$(cd "$(git -C "$WT" rev-parse --git-common-dir)" && pwd -P)"
HQ_GIT="$(cd "$HQ_ROOT/.git" 2>/dev/null && pwd -P || echo "/nonexistent")"
BRANCH="$(git -C "$WT" symbolic-ref -q --short HEAD 2>/dev/null || echo "")"
HEAD_SHA="$(git -C "$WT" rev-parse --short HEAD 2>/dev/null || echo "none")"
N_FILES="?"
[ "$COMMON_P" != "$HQ_GIT" ] || kept "worktree belongs to the HQ root repo; HQ is never committed or pushed by this flow"
[ "$GIT_DIR_P" != "$COMMON_P" ] || kept "not a linked worktree (this is the repo's main checkout)"

# ---- 3: size
PATHS="$(mktemp "${TMPDIR:-/tmp}/hq-preserve.XXXXXX")" || { echo "worktree-preserve: mktemp failed" >&2; exit 2; }
trap 'rm -f "$PATHS"' EXIT
# Everything that differs from HEAD (staged or not, including deletions) plus
# untracked files that are not ignored, one path per line. Content someone
# already `git add`ed counts: it is what the commit would ship.
{
  git -C "$WT" -c core.quotePath=false diff --name-only --no-renames HEAD 2>/dev/null
  git -C "$WT" -c core.quotePath=false ls-files -o --exclude-standard 2>/dev/null
} >"$PATHS"
sort -u -o "$PATHS" "$PATHS"
N_FILES="$(grep -c . "$PATHS" || true)"
if [ "$N_FILES" -eq 0 ]; then
  ledger CLEAN "$BRANCH" "$HEAD_SHA" 0 "nothing to preserve"
  say CLEAN "nothing to preserve"
  exit 0
fi
if [ "$N_FILES" -gt "$MAX_FILES" ] && [ -z "$ALLOW_LARGE" ]; then
  kept "$N_FILES changed paths exceed the ceiling of $MAX_FILES; a worktree never legitimately preserves that many (pass --allow-large \"<reason>\" to override)"
fi
if [ -z "$ALLOW_LARGE" ]; then
  BYTES=0
  while IFS= read -r p; do
    [ -f "$WT/$p" ] || continue
    sz="$(wc -c <"$WT/$p" 2>/dev/null | tr -d ' ')" || sz=0
    BYTES=$((BYTES + sz))
    [ "$BYTES" -le "$MAX_BYTES" ] || kept "changed files exceed $MAX_BYTES bytes (pass --allow-large \"<reason>\" to override)"
  done <"$PATHS"
fi

# ---- 4: HQ-root markers (never overridable)
hqm_load "$HQ_ROOT" || exit 2
HITS="$(hqm_scan "$WT" HEAD "$PATHS")" || {
  echo "worktree-preserve: HQ-root marker paths in $WT:" >&2
  printf '%s\n' "$HITS" | sed 's/^/  /' >&2
  kept "HQ-root marker paths present ($(printf '%s\n' "$HITS" | head -1 | cut -f1), see stderr); this tree holds foreign content, not worktree work"
}

if [ "$DRY" -eq 1 ]; then
  act="would commit $N_FILES paths"
  [ "$PUSH" -eq 1 ] && act="$act and push"
  ledger DRY-RUN "$BRANCH" "$HEAD_SHA" "$N_FILES" "$act"
  say DRY-RUN "$act"
  exit 0
fi

# ---- 5: stage and scan
git -C "$WT" add -A || kept "git add failed"
if [ -f "$HQ_ROOT/core/scripts/commit-secret-scan.sh" ]; then
  export HQ_ROOT
  if ! (cd "$WT" && bash "$HQ_ROOT/core/scripts/commit-secret-scan.sh" gate); then
    git -C "$WT" reset -q
    kept "commit secret scan blocked (possible secret, or the scanner is unavailable); nothing committed"
  fi
else
  git -C "$WT" reset -q
  kept "commit-secret-scan.sh missing under $HQ_ROOT; refusing to commit unscanned"
fi

# ---- 6: commit, with the repo's hooks. Never onto main/master or a detached
# HEAD: the commit goes on wip/<slug>-<date> so the shared local main ref is
# left where it was.
WIP="wip/$SLUG-$DATE"
case "$BRANCH" in
  ""|main|master)
    git -C "$WT" checkout -q -b "$WIP" 2>/dev/null || { git -C "$WT" reset -q; kept "could not create branch $WIP for the wip commit"; }
    BRANCH="$WIP" ;;
esac
MSG="wip: preserve worktree $NAME before removal ($DATE)"
if ! git -C "$WT" commit -q -m "$MSG"; then
  git -C "$WT" reset -q
  kept "git commit failed or was blocked by a hook; nothing committed"
fi
SHA="$(git -C "$WT" rev-parse --short HEAD)"
N_COMMITTED="$(git -C "$WT" diff-tree --no-commit-id --name-only -r HEAD | grep -c . || true)"

if [ "$PUSH" -eq 0 ]; then
  ledger COMMITTED "${BRANCH:-detached}" "$SHA" "$N_COMMITTED" "$MSG"
  say COMMITTED "$SHA ${BRANCH:-detached} $N_COMMITTED files"
  exit 0
fi

# ---- 7: push, never main/master
REMOTE="$(git -C "$WT" config --get "branch.${BRANCH:-x}.remote" 2>/dev/null || true)"
[ -n "$REMOTE" ] || REMOTE=origin
git -C "$WT" remote get-url "$REMOTE" >/dev/null 2>&1 || { ledger COMMITTED "${BRANCH:-detached}" "$SHA" "$N_COMMITTED" "committed; no remote '$REMOTE' to push to"; say COMMITTED "$SHA ${BRANCH:-detached} $N_COMMITTED files (no remote '$REMOTE')"; exit 0; }
TARGET="$BRANCH"
if git -C "$WT" push -q "$REMOTE" "$BRANCH"; then
  git -C "$WT" branch -q --set-upstream-to="$REMOTE/$BRANCH" "$BRANCH" 2>/dev/null
  ledger PUSHED "$TARGET" "$SHA" "$N_COMMITTED" "$MSG"
  say PUSHED "$SHA $REMOTE/$TARGET $N_COMMITTED files"
  exit 0
fi
ledger COMMITTED "$TARGET" "$SHA" "$N_COMMITTED" "committed; push to $REMOTE/$TARGET was rejected"
say COMMITTED "$SHA $N_COMMITTED files; push to $REMOTE/$TARGET rejected (see above)"
exit 0
