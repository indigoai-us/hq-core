#!/bin/bash
# hq-core: public
# free-disk-space.sh — find and reclaim disk space used by HQ and common dev caches.
#
# Usage:
#   free-disk-space.sh scan                 # report free space and the largest reclaimable areas
#   free-disk-space.sh worktrees-status     # per-project count/size of HQ worktrees
#   free-disk-space.sh prune-backed-up [H]  # delete worktrees that are clean, pushed, stash-free,
#                                           #   and untouched for H hours (default 6)
#   free-disk-space.sh slim-idle [D]        # in worktrees idle D days (default 7), delete git-ignored
#                                           #   dependency/build folders (node_modules, target, dist, ...)
#   free-disk-space.sh caches               # clear ~/Library/Caches, npm cache, and safe ~/.cache entries
#
# Never deletes uncommitted, unpushed, or stashed work. Keeps the qmd search index
# and Codex runtimes in ~/.cache. Every mutating mode prints GB freed.

set -u
HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
WT_ROOT="$HQ_ROOT/workspace/worktrees"
BUILD_DIRS='node_modules target dist build .next .turbo .svelte-kit .vite .cache coverage out'
SAFE_DOT_CACHE='gh prisma node agent-browser'

free_kb() { df -k / | tail -1 | awk '{print $4}'; }
report_freed() { echo "freedGB=$(( ($(free_kb) - $1) / 1048576 ))"; df -h / | tail -1; }

worktree_dirs() {
  [ -d "$WT_ROOT" ] || return 0
  find "$WT_ROOT" -maxdepth 3 -name .git 2>/dev/null | while IFS= read -r g; do dirname "$g"; done
}

cmd_scan() {
  df -h / | tail -1
  du -sh "$WT_ROOT" "$HOME/Library/Caches" "$HOME/.cache" "$HOME/.npm" \
    "$HOME/Library/Developer" "$HOME/Library/Application Support/Claude" \
    "$HOME/Downloads" "$HOME/.Trash" 2>/dev/null | sort -hr
}

cmd_worktrees_status() {
  for p in "$WT_ROOT"/*/; do
    url=$(git -C "$p" remote get-url origin 2>/dev/null)
    name=$(basename "${url%.git}"); [ -z "$name" ] && name="(no-repo)"
    echo "$name $(du -sk "$p" | cut -f1)"
  done | awk '{n[$1]++; s[$1]+=$2} END {for (k in n) printf "%d\t%.1f GB\t%s\n", n[k], s[k]/1048576, k}' | sort -k2 -nr
}

cmd_prune_backed_up() {
  local hours=${1:-6} before del=0 kept=0
  before=$(free_kb)
  while IFS= read -r p; do
    dirty=$(git -C "$p" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    up=$(git -C "$p" rev-parse --abbrev-ref '@{u}' 2>/dev/null) || up=""
    unp=$(git -C "$p" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 1)
    st=$(git -C "$p" stash list 2>/dev/null | wc -l | tr -d ' ')
    recent=$(find "$p" -maxdepth 1 -mmin -$(( hours * 60 )) 2>/dev/null | head -1)
    if [ "$dirty" = 0 ] && [ -n "$up" ] && [ "$unp" = 0 ] && [ "$st" = 0 ] && [ -z "$recent" ]; then
      common=$(git -C "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
      linked=0; [ -f "$p/.git" ] && linked=1
      rm -rf "$p"
      [ "$linked" = 1 ] && [ -n "$common" ] && git --git-dir="$common" worktree prune 2>/dev/null
      echo "removed $p"; del=$((del+1))
    else
      kept=$((kept+1))
    fi
  done < <(worktree_dirs)
  echo "deleted=$del kept=$kept"
  report_freed "$before"
}

cmd_slim_idle() {
  local days=${1:-7} before slimmed=0 skipped=0 prune=""
  before=$(free_kb)
  for n in $BUILD_DIRS; do prune="$prune -name $n -o"; done
  for p in "$WT_ROOT"/*/; do
    p=${p%/}
    ct=$(git -C "$p" log -1 --format=%ct 2>/dev/null || echo 0)
    if [ $(( $(date +%s) - ct )) -lt $(( days * 86400 )) ]; then skipped=$((skipped+1)); continue; fi
    # shellcheck disable=SC2086
    recent=$(find "$p" \( -name .git $prune -false \) -prune -o -type f -mtime -"$days" -print 2>/dev/null | head -1)
    if [ -n "$recent" ]; then skipped=$((skipped+1)); continue; fi
    for n in $BUILD_DIRS; do
      find "$p" -name .git -prune -o -type d -name "$n" -prune -print 2>/dev/null | while IFS= read -r d; do
        git -C "$p" check-ignore -q "$d" 2>/dev/null && rm -rf "$d"
      done
    done
    slimmed=$((slimmed+1))
  done
  echo "slimmed=$slimmed skipped_recent=$skipped"
  report_freed "$before"
}

cmd_caches() {
  local before; before=$(free_kb)
  rm -rf "$HOME/Library/Caches/"* 2>/dev/null
  command -v npm >/dev/null && npm cache clean --force >/dev/null 2>&1
  for c in $SAFE_DOT_CACHE; do rm -rf "${HOME:?}/.cache/$c"; done
  report_freed "$before"
}

case "${1:-scan}" in
  scan) cmd_scan ;;
  worktrees-status) cmd_worktrees_status ;;
  prune-backed-up) cmd_prune_backed_up "${2:-6}" ;;
  slim-idle) cmd_slim_idle "${2:-7}" ;;
  caches) cmd_caches ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
