#!/bin/bash
# hq-core: public
# free-disk-space.sh — find and reclaim disk space used by HQ and common dev caches.
#
# Usage:
#   free-disk-space.sh [--apply] scan
#   free-disk-space.sh [--apply] worktrees-status
#   free-disk-space.sh [--apply] prune-backed-up [H]
#   free-disk-space.sh [--apply] slim-idle [D]
#   free-disk-space.sh [--apply] caches
#
# Mutating modes dry-run unless --apply is present. prune-backed-up removes
# only linked git worktrees (a .git file whose git dir is under the common
# dir's worktrees/) via `git worktree remove`. It never rm -rf's a checkout.
# A worktree is kept when it is dirty, lacks an upstream, has unpushed commits
# on a branch checked out there (current branch or reflog), has a stash, was
# touched in the last H hours (default 6; a file anywhere in the tree, or its
# HEAD / HEAD reflog), has skip-worktree or assume-unchanged index flags, a nested
# git repo, or ignored files outside the rebuildable allowlist. A worktree owned
# by a session is also kept: a live process has its cwd inside it (live-session),
# or a Claude Code / Codex transcript written in the last 7 days recorded a cwd
# inside it (recent-session; env HQ_WORKTREE_SESSION_WINDOW_HOURS). slim-idle
# skips session-owned worktrees too.
# caches deletes only the named developer cache allowlist below.

set -u
HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
WT_ROOT="$HQ_ROOT/workspace/worktrees"
BUILD_DIRS='node_modules target dist build .next .turbo .svelte-kit .vite .cache coverage out'
# Leading path component only, space-padded. "config/out/creds.json" is not "out".
ALLOW_IGNORED_DIRS=" $BUILD_DIRS "
# ~/.cache entries that are safe to rebuild. qmd and Codex runtimes are absent on purpose.
SAFE_DOT_CACHE='gh prisma node agent-browser'
# ~/Library/Caches directory names that are safe to rebuild. Not a glob.
LIB_CACHE_NAMES='Homebrew pip Yarn npm pnpm node-gyp go-build cargo turbo typescript electron'
APPLY=0

# ---------------------------- session liveness ------------------------------
# A worktree is owned by a live session when a running process has its cwd
# inside it (lsof on macOS, /proc on Linux), or when a Claude Code / Codex
# session transcript written within the session window recorded a cwd inside
# it. Agent shells do not keep a process parked in the worktree between tool
# calls, so the transcript cwd is what covers an idle but open session. Both
# lists are gathered once per run. With no lsof and no /proc the process probe
# yields nothing; the transcript, reference, and activity guards still apply.
SESSION_WINDOW_HOURS="${HQ_WORKTREE_SESSION_WINDOW_HOURS:-168}"
case "$SESSION_WINDOW_HOURS" in ''|*[!0-9]*) SESSION_WINDOW_HOURS=168 ;; esac
LIVE_PROC_CWDS=""
SESSION_CWDS=""
collect_session_cwds() {
  local _p d dirs
  LIVE_PROC_CWDS="$(mktemp "${TMPDIR:-/tmp}/hq-wt-proc.XXXXXX" 2>/dev/null)" || LIVE_PROC_CWDS=""
  SESSION_CWDS="$(mktemp "${TMPDIR:-/tmp}/hq-wt-sess.XXXXXX" 2>/dev/null)" || SESSION_CWDS=""
  if [ -n "$LIVE_PROC_CWDS" ]; then
    if [ -e /proc/self/cwd ]; then
      for _p in /proc/[0-9]*; do readlink "$_p/cwd" 2>/dev/null || true; done > "$LIVE_PROC_CWDS"
    elif command -v lsof >/dev/null 2>&1; then
      { lsof -w -n -P -d cwd -Fn 2>/dev/null || true; } | sed -n 's/^n//p' > "$LIVE_PROC_CWDS"
    fi
  fi
  if [ -n "$SESSION_CWDS" ]; then
    dirs="${HQ_SESSION_TRANSCRIPT_DIRS:-$HOME/.claude/projects:$HOME/.codex/sessions}"
    printf '%s\n' "$dirs" | tr ':' '\n' | while IFS= read -r d; do
      [ -n "$d" ] && [ -d "$d" ] || continue
      { find "$d" -type f -name '*.jsonl' -mmin "-$((SESSION_WINDOW_HOURS * 60))" -print0 2>/dev/null \
          | xargs -0 grep -h -o '"cwd": *"[^"]*"' /dev/null 2>/dev/null || true; } \
        | sed 's/^"cwd": *"//; s/"$//'
    done | sort -u > "$SESSION_CWDS"
  fi
}

# path_in_list <list-file> <path> [<alt-path>] — true when a listed cwd is the
# path or lies inside it.
path_in_list() {
  local f="$1" a="${2:-}" b="${3:-}"
  [ -n "$f" ] && [ -s "$f" ] || return 1
  awk -v a="$a" -v b="$b" '
    function hit(p, w) { return w != "" && (p == w || index(p, w "/") == 1) }
    hit($0, a) || hit($0, b) { found = 1; exit }
    END { exit found ? 0 : 1 }' "$f"
}

# session_owner_reason <wt> [<alt>] — prints live-session or recent-session and
# succeeds when a session owns the worktree.
session_owner_reason() {
  if path_in_list "$LIVE_PROC_CWDS" "$1" "${2:-}"; then echo "live-session"; return 0; fi
  if path_in_list "$SESSION_CWDS" "$1" "${2:-}"; then echo "recent-session"; return 0; fi
  return 1
}

cleanup_session_lists() { rm -f "${LIVE_PROC_CWDS:-}" "${SESSION_CWDS:-}"; }
trap cleanup_session_lists EXIT

# 0 when a file in the worktree (outside .git and build dirs), or its HEAD or
# HEAD reflog, changed in the last <minutes>.
recently_touched() {
  local p="$1" mins="$2" gd hit
  hit=$(find "$p" -mindepth 1 \
    \( -name .git -o -name node_modules -o -name target -o -name dist -o -name build -o -name .next -o -name .turbo -o -name .svelte-kit -o -name .vite -o -name .cache -o -name coverage -o -name out \) -prune -o \
    -mmin "-$mins" -print 2>/dev/null | head -1 || true)
  [ -n "$hit" ] && return 0
  hit=$(find "$p" -maxdepth 0 -mmin "-$mins" 2>/dev/null || true)
  [ -n "$hit" ] && return 0
  gd=$(git -C "$p" rev-parse --path-format=absolute --git-dir 2>/dev/null) || gd=""
  if [ -n "$gd" ]; then
    hit=$(find "$gd/HEAD" "$gd/logs/HEAD" -maxdepth 0 -mmin "-$mins" 2>/dev/null | head -1 || true)
    [ -n "$hit" ] && return 0
  fi
  return 1
}

usage() {
  sed -n '2,22p' "$0"
}

free_kb() { df -k / | tail -1 | awk '{print $4}'; }
report_freed() { echo "freedGB=$(( ($(free_kb) - $1) / 1048576 ))"; df -h / | tail -1; }

worktree_dirs() {
  [ -d "$WT_ROOT" ] || return 0
  find "$WT_ROOT" -maxdepth 3 -name .git 2>/dev/null | while IFS= read -r g; do dirname "$g"; done
}

# Linked worktree: .git is a file, and git's own git-dir sits under common/worktrees/.
is_linked_worktree() {
  local p="$1" git_dir common
  [ -f "$p/.git" ] || return 1
  [ -d "$p/.git" ] && return 1
  git_dir=$(git -C "$p" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
  common=$(git -C "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$git_dir" ] && [ -n "$common" ] && [ "$git_dir" != "$common" ] || return 1
  case "$git_dir/" in
    "$common"/worktrees/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Rebuildable only when the first path component is an allowlisted directory name.
path_is_rebuildable() {
  local rel="$1" top
  rel="${rel#./}"
  rel="${rel%/}"
  top="${rel%%/*}"
  case "$ALLOW_IGNORED_DIRS" in
    *" $top "*) return 0 ;;
  esac
  return 1
}

same_dir() {
  local a b
  a=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  b=$(cd "$2" 2>/dev/null && pwd -P) || return 1
  [ "$a" = "$b" ]
}

# True only for a checkout whose toplevel is this directory, not a parent repo.
is_worktree_root() {
  local p="$1" top
  top=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) || return 1
  same_dir "$p" "$top"
}

# 0 when this directory contains a .git file or directory at any depth.
# find prints the first hit and quits. A failed search is treated as a hit
# so the directory is not deleted.
contains_git_entry() {
  local dir="$1" hit
  [ -d "$dir" ] || return 1
  hit=$(find "$dir" -name .git -print -quit 2>/dev/null) || return 0
  [ -n "$hit" ]
}

# First allowlisted top-level directory that contains a nested git repo.
rebuildable_dir_with_git() {
  local p="$1" n
  set -f
  # shellcheck disable=SC2086
  for n in $BUILD_DIRS; do
    [ -d "$p/$n" ] || continue
    if contains_git_entry "$p/$n"; then
      printf '%s\n' "$n"
      set +f
      return 0
    fi
  done
  set +f
  return 1
}

# Ignored paths that are not inside a rebuildable build/cache directory.
# A rebuildable directory that itself contains a .git entry is a blocker:
# find names `build` before it reaches `build/vendor/.git`.
ignored_blockers() {
  local p="$1" rel
  git -C "$p" ls-files --others -i --exclude-standard --directory 2>/dev/null | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if path_is_rebuildable "$rel"; then
      if contains_git_entry "$p/${rel%/}"; then
        printf '%s\n' "${rel%/}"
      fi
      continue
    fi
    printf '%s\n' "${rel%/}"
  done
}

# Branches checked out in this worktree: HEAD, plus names in this worktree's reflog.
branches_checked_out_here() {
  local p="$1" cur msg from to
  cur=$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null) || cur=""
  if [ -n "$cur" ] && [ "$cur" != "HEAD" ]; then
    printf '%s\n' "$cur"
  fi
  git -C "$p" reflog show HEAD --format='%gs' 2>/dev/null | while IFS= read -r msg; do
    case "$msg" in
      "checkout: moving from "*" to "*)
        from=${msg#checkout: moving from }
        from=${from%% to *}
        to=${msg##* to }
        printf '%s\n' "$from" "$to"
        ;;
    esac
  done
}

# Prints one unpushed branch name checked out here, if any.
unpushed_checked_out_branch() {
  local p="$1" b up count
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    [ "$b" = "HEAD" ] && continue
    git -C "$p" show-ref --verify --quiet "refs/heads/$b" || continue
    up=$(git -C "$p" rev-parse --abbrev-ref "${b}@{u}" 2>/dev/null) || up=""
    if [ -n "$up" ]; then
      count=$(git -C "$p" rev-list --count "${up}..${b}" 2>/dev/null) || count=1
    else
      count=$(git -C "$p" rev-list --count "${b}" --not --remotes 2>/dev/null) || count=1
    fi
    if [ "${count:-1}" != "0" ]; then
      printf '%s\n' "$b"
      return 0
    fi
  done <<EOF
$(branches_checked_out_here "$p" | sort -u)
EOF
  return 1
}

# skip-worktree (tag S, or s when also assume-unchanged) and assume-unchanged
# (any lowercase tag) hide local edits from git status and git worktree remove.
# A failed listing is treated as hidden so nothing is deleted.
hidden_local_changes() {
  local p="$1" listing line tag
  listing=$(git -C "$p" ls-files -v 2>/dev/null) || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tag=${line%% *}
    case "$tag" in
      S|[a-z]) return 0 ;;
    esac
  done <<EOF
$listing
EOF
  return 1
}

# Ignored allowlisted dirs at the top of this worktree only.
# Does not enter submodules (.git inside a child) and does not match config/out.
# A directory with any tracked path (force-added, skip-worktree, or
# assume-unchanged) is not rebuildable. A failed ls-files skips it too.
# A .git entry at any depth (a nested clone) skips it too.
ignored_rebuildable_dirs() {
  local p="$1" n d rel top tracked
  set -f
  # shellcheck disable=SC2086
  for n in $BUILD_DIRS; do
    find "$p" -mindepth 1 \
      \( -name .git -o -exec test -e '{}/.git' \; \) -prune -o \
      -type d -name "$n" -prune -print 2>/dev/null | while IFS= read -r d; do
      [ -n "$d" ] || continue
      rel=${d#"$p"/}
      top=${rel%%/*}
      case "$ALLOW_IGNORED_DIRS" in
        *" $top "*) ;;
        *) continue ;;
      esac
      git -C "$p" check-ignore -q -- "$d" 2>/dev/null || continue
      tracked=$(git -C "$p" ls-files -v -- "$d" 2>/dev/null) || continue
      [ -z "$tracked" ] || continue
      contains_git_entry "$d" && continue
      printf '%s\n' "$d"
    done
  done
  set +f
}

clear_rebuildable_dirs() {
  local p="$1" d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    rm -rf "$d"
  done <<EOF
$(ignored_rebuildable_dirs "$p")
EOF
}

# A commit that appears in this worktree's HEAD reflog but not on any remote.
reflog_commit_not_on_remote() {
  local p="$1" sha count
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    case "$sha" in
      [0-9a-f]*) ;;
      *) continue ;;
    esac
    count=$(git -C "$p" rev-list --count "$sha" --not --remotes 2>/dev/null) || count=1
    if [ "${count:-1}" != "0" ]; then
      printf '%s\n' "$sha"
      return 0
    fi
  done <<EOF
$(git -C "$p" reflog show HEAD --format='%H' 2>/dev/null | sort -u)
EOF
  return 1
}

remove_linked_worktree() {
  local p="$1" common
  # Callers report reason=hidden-local-changes or reason=nested-git.
  # Refuse again before any rm.
  if hidden_local_changes "$p"; then
    return 1
  fi
  if [ -n "$(rebuildable_dir_with_git "$p" || true)" ]; then
    return 1
  fi
  common=$(git -C "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  # Safety checks have already passed. Only ignored rebuildable dirs are cleared,
  # and only so they cannot block `git worktree remove`. Never --force, never rm -rf the root.
  clear_rebuildable_dirs "$p"
  git --git-dir="$common" worktree remove -- "$p"
}

cmd_scan() {
  local budget="${HQ_FREE_DISK_SCAN_TIMEOUT_SECS:-5}" tmp="" i=0 ticks=0 alive=0
  local path="" pid="" size="" out=""
  local -a paths pids

  case "$budget" in ''|*[!0-9]*) budget=5 ;; esac
  [ "$budget" -ge 1 ] 2>/dev/null || budget=5
  # This diagnostic runs when the disk is already in trouble. Keep its
  # wall-clock cost bounded even if an override is accidentally too large.
  [ "$budget" -le 10 ] 2>/dev/null || budget=10

  df -h / | tail -1
  echo "largest reclaimable areas (bounded scan):"
  printf '%10s  %-9s  %s\n' "SIZE" "STATUS" "PATH"

  paths=(
    "$WT_ROOT"
    "$HOME/Library/Caches"
    "$HOME/.cache"
    "$HOME/.npm"
    "$HOME/Library/Developer"
    "$HOME/Library/Application Support/Claude"
    "$HOME/Downloads"
    "$HOME/.Trash"
  )

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/hq-disk-scan.XXXXXX" 2>/dev/null)" || tmp=""
  if [ -z "$tmp" ]; then
    for path in "${paths[@]}"; do
      printf '%10s  %-9s  %s\n' "unknown" "unavailable" "$path"
    done
    return 0
  fi

  # Probe the fixed allowlist concurrently. One slow or unreadable tree must
  # not suppress results from the others, and the table stays at eight rows.
  for path in "${paths[@]}"; do
    out="$tmp/$i.out"
    if [ ! -e "$path" ]; then
      printf '0\tmissing\t%s\n' "$path" >"$tmp/$i.result"
      pids[$i]=""
      i=$((i + 1))
      continue
    fi
    (
      if du -sk "$path" >"$out" 2>/dev/null; then
        : >"$tmp/$i.done"
      else
        : >"$tmp/$i.failed"
      fi
    ) &
    pids[$i]=$!
    i=$((i + 1))
  done

  ticks=$((budget * 10))
  while [ "$ticks" -gt 0 ]; do
    alive=0
    i=0
    for path in "${paths[@]}"; do
      pid="${pids[$i]:-}"
      if [ -n "$pid" ] && [ ! -f "$tmp/$i.done" ] && [ ! -f "$tmp/$i.failed" ] && kill -0 "$pid" 2>/dev/null; then
        alive=1
        break
      fi
      i=$((i + 1))
    done
    [ "$alive" -eq 1 ] || break
    sleep 0.1
    ticks=$((ticks - 1))
  done

  i=0
  for path in "${paths[@]}"; do
    pid="${pids[$i]:-}"
    if [ -n "$pid" ] && [ ! -f "$tmp/$i.done" ] && [ ! -f "$tmp/$i.failed" ] && kill -0 "$pid" 2>/dev/null; then
      : >"$tmp/$i.timeout"
      kill -TERM "$pid" 2>/dev/null || true
    fi
    i=$((i + 1))
  done
  sleep 0.1
  i=0
  for path in "${paths[@]}"; do
    pid="${pids[$i]:-}"
    if [ -n "$pid" ]; then
      if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
      wait "$pid" 2>/dev/null || true
    fi
    i=$((i + 1))
  done

  i=0
  for path in "${paths[@]}"; do
    if [ -f "$tmp/$i.result" ]; then
      :
    elif [ -f "$tmp/$i.done" ]; then
      size="$(awk 'NR == 1 && $1 ~ /^[0-9]+$/ { print $1 }' "$tmp/$i.out" 2>/dev/null)"
      if [ -n "$size" ]; then
        printf '%s\tok\t%s\n' "$size" "$path" >"$tmp/$i.result"
      else
        printf '0\terror\t%s\n' "$path" >"$tmp/$i.result"
      fi
    elif [ -f "$tmp/$i.timeout" ]; then
      printf '0\ttimeout\t%s\n' "$path" >"$tmp/$i.result"
    else
      printf '0\terror\t%s\n' "$path" >"$tmp/$i.result"
    fi
    cat "$tmp/$i.result" >>"$tmp/results"
    i=$((i + 1))
  done

  sort -k1,1nr "$tmp/results" | awk -F '\t' '
    function human(kb) {
      if (kb >= 1048576) return sprintf("%.1f GB", kb / 1048576)
      if (kb >= 1024) return sprintf("%.1f MB", kb / 1024)
      return sprintf("%d KB", kb)
    }
    {
      shown = ($2 == "ok" ? human($1) : ($2 == "missing" ? "0 KB" : "unknown"))
      printf "%10s  %-9s  %s\n", shown, $2, $3
    }'
  rm -rf -- "$tmp"
}

cmd_worktrees_status() {
  for p in "$WT_ROOT"/*/; do
    [ -d "$p" ] || continue
    url=$(git -C "$p" remote get-url origin 2>/dev/null) || url=""
    name=$(basename "${url%.git}"); [ -z "$name" ] && name="(no-repo)"
    echo "$name $(du -sk "$p" | cut -f1)"
  done | awk '{n[$1]++; s[$1]+=$2} END {for (k in n) printf "%d\t%.1f GB\t%s\n", n[k], s[k]/1048576, k}' | sort -k2 -nr
}

cmd_prune_backed_up() {
  local hours=${1:-6} before del=0 kept=0 would=0
  local p status_out dirty up unp st recent blockers side lost nested
  case "$hours" in
    ''|*[!0-9]*) hours=6 ;;
  esac
  before=$(free_kb)
  if [ "$APPLY" = 1 ]; then echo "mode=apply"; else echo "mode=dry-run"; fi
  collect_session_cwds
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if owner=$(session_owner_reason "$p" "$(cd "$p" 2>/dev/null && pwd -P)"); then
      echo "kept $p reason=$owner"
      kept=$((kept + 1))
      continue
    fi
    if [ -d "$p/.git" ]; then
      echo "kept $p reason=full-clone"
      kept=$((kept + 1))
      continue
    fi
    if ! is_linked_worktree "$p"; then
      echo "kept $p reason=not-linked-worktree"
      kept=$((kept + 1))
      continue
    fi
    if ! is_worktree_root "$p"; then
      echo "kept $p reason=not-worktree-root"
      kept=$((kept + 1))
      continue
    fi
    if git -C "$p" ls-files -s 2>/dev/null | grep -q '^160000 '; then
      echo "kept $p reason=submodule"
      kept=$((kept + 1))
      continue
    fi
    # Command-line flags override status.showUntrackedFiles=no. A failure is dirty.
    status_out=$(git -C "$p" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) || status_out="?"
    if [ -n "$status_out" ]; then dirty=1; else dirty=0; fi
    if hidden_local_changes "$p"; then
      echo "kept $p reason=hidden-local-changes"
      kept=$((kept + 1))
      continue
    fi
    up=$(git -C "$p" rev-parse --abbrev-ref '@{u}' 2>/dev/null) || up=""
    unp=$(git -C "$p" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 1)
    st=$(git -C "$p" stash list 2>/dev/null | wc -l | tr -d ' ')
    recent=""
    if recently_touched "$p" "$((hours * 60))"; then recent=1; fi
    side=$(unpushed_checked_out_branch "$p" || true)
    lost=$(reflog_commit_not_on_remote "$p" || true)
    blockers=$(ignored_blockers "$p" | head -8 | paste -sd, - || true)
    if [ "$dirty" != 0 ]; then
      echo "kept $p reason=dirty"; kept=$((kept + 1)); continue
    fi
    if [ -z "$up" ]; then
      echo "kept $p reason=no-upstream"; kept=$((kept + 1)); continue
    fi
    if [ "$unp" != 0 ]; then
      echo "kept $p reason=unpushed"; kept=$((kept + 1)); continue
    fi
    if [ -n "$side" ]; then
      echo "kept $p reason=unpushed-branch:$side"; kept=$((kept + 1)); continue
    fi
    if [ -n "$lost" ]; then
      echo "kept $p reason=reflog-not-pushed:$lost"; kept=$((kept + 1)); continue
    fi
    if [ "$st" != 0 ]; then
      echo "kept $p reason=stash"; kept=$((kept + 1)); continue
    fi
    if [ -n "$recent" ]; then
      echo "kept $p reason=recent"; kept=$((kept + 1)); continue
    fi
    nested=$(rebuildable_dir_with_git "$p" || true)
    if [ -n "$nested" ]; then
      echo "kept $p reason=nested-git:$nested"
      kept=$((kept + 1))
      continue
    fi
    if [ -n "$blockers" ]; then
      echo "kept $p reason=ignored:$blockers"; kept=$((kept + 1)); continue
    fi
    if [ "$APPLY" != 1 ]; then
      echo "would-remove $p"
      would=$((would + 1))
      continue
    fi
    if remove_linked_worktree "$p"; then
      echo "removed $p"
      del=$((del + 1))
    else
      echo "kept $p reason=worktree-remove-failed"
      kept=$((kept + 1))
    fi
  done < <(worktree_dirs)
  echo "deleted=$del kept=$kept would_delete=$would"
  if [ "$APPLY" = 1 ]; then
    report_freed "$before"
  fi
}

cmd_slim_idle() {
  local days=${1:-7} before slimmed=0 skipped=0 p ct recent d nested
  case "$days" in
    ''|*[!0-9]*) days=7 ;;
  esac
  before=$(free_kb)
  if [ "$APPLY" = 1 ]; then echo "mode=apply"; else echo "mode=dry-run"; fi
  collect_session_cwds
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # Grouping dirs (worktrees/<repo>/<name>) are not checkouts. git -C on them
    # walks up to the HQ repo, whose ignore rules must not decide deletions.
    is_worktree_root "$p" || continue
    if owner=$(session_owner_reason "$p" "$(cd "$p" 2>/dev/null && pwd -P)"); then
      echo "kept $p reason=$owner"
      skipped=$((skipped + 1))
      continue
    fi
    if hidden_local_changes "$p"; then
      echo "kept $p reason=hidden-local-changes"
      skipped=$((skipped + 1))
      continue
    fi
    ct=$(git -C "$p" log -1 --format=%ct 2>/dev/null || echo 0)
    case "$ct" in
      ''|*[!0-9]*) ct=0 ;;
    esac
    if [ $(( $(date +%s) - ct )) -lt $(( days * 86400 )) ]; then skipped=$((skipped + 1)); continue; fi
    recent=$(find "$p" -mindepth 1 \
      \( -name .git -o -exec test -e '{}/.git' \; -o -name node_modules -o -name target -o -name dist -o -name build -o -name .next -o -name .turbo -o -name .svelte-kit -o -name .vite -o -name .cache -o -name coverage -o -name out \) -prune -o \
      -type f -mtime -"$days" -print 2>/dev/null | head -1 || true)
    if [ -n "$recent" ]; then skipped=$((skipped + 1)); continue; fi
    nested=$(rebuildable_dir_with_git "$p" || true)
    if [ -n "$nested" ]; then
      echo "kept $p reason=nested-git:$nested"
      skipped=$((skipped + 1))
      continue
    fi
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      if [ "$APPLY" = 1 ]; then
        rm -rf "$d"
        echo "removed $d"
      else
        echo "would-remove $d"
      fi
    done <<EOF
$(ignored_rebuildable_dirs "$p")
EOF
    slimmed=$((slimmed + 1))
  done < <(worktree_dirs)
  echo "slimmed=$slimmed skipped_recent=$skipped"
  if [ "$APPLY" = 1 ]; then
    report_freed "$before"
  fi
}

remove_cache_path() {
  local path="$1"
  [ -e "$path" ] || return 0
  if [ "$APPLY" = 1 ]; then
    rm -rf "$path"
    echo "removed $path"
  else
    echo "would-remove $path"
  fi
}

cmd_caches() {
  local before name path
  before=$(free_kb)
  if [ "$APPLY" = 1 ]; then echo "mode=apply"; else echo "mode=dry-run"; fi
  set -f
  # shellcheck disable=SC2086
  for name in $LIB_CACHE_NAMES; do
    remove_cache_path "$HOME/Library/Caches/$name"
  done
  # shellcheck disable=SC2086
  for name in $SAFE_DOT_CACHE; do
    remove_cache_path "$HOME/.cache/$name"
  done
  set +f
  if command -v npm >/dev/null 2>&1; then
    if [ "$APPLY" = 1 ]; then
      npm cache clean --force >/dev/null 2>&1 || true
      echo "removed npm-cache"
    else
      echo "would-remove npm-cache"
    fi
  fi
  if [ "$APPLY" = 1 ]; then
    report_freed "$before"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *) break ;;
  esac
done

cmd="${1:-scan}"
extra="${2:-}"
case "$cmd" in
  scan) cmd_scan ;;
  worktrees-status) cmd_worktrees_status ;;
  prune-backed-up) cmd_prune_backed_up "${extra:-6}" ;;
  slim-idle) cmd_slim_idle "${extra:-7}" ;;
  caches) cmd_caches ;;
  *) usage; exit 2 ;;
esac
