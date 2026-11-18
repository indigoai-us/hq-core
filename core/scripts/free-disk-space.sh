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
#   free-disk-space.sh [--apply --yes] prune-hq-history
#   free-disk-space.sh [--apply --yes] trash-disabled-mirror
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
#
# prune-hq-history runs `git prune --expire=1.hour.ago` on the HQ root git
# (<hq>/.git). It deletes only loose objects that no commit, ref, reflog, or
# index reaches and that are over an hour old, so objects a running git
# command just wrote (not yet referenced) are kept. It holds the autosave
# lock while it runs. A dry run lists what would go and its size on disk.
# trash-disabled-mirror moves an HQ sync git recovery copy that sync has
# disabled (~/.hq/hq-root-git/<id> with hq-sync-mirror-disabled.json) to the
# Trash, only when every object in it (commits reachable from its refs, HEAD
# and reflogs, and unreferenced objects) exists in the current HQ root's git.
# Copies with a missing object, an unreadable store, or a shallow HQ root are
# kept, and so is a non-bare copy with an index or working-tree changes.
# prune-hq-history refuses while a repo under the HQ root or a recovery copy
# borrows the HQ root's objects through objects/info/alternates.
# It never deletes. Both modes need --apply and --yes; --yes records that
# the user confirmed the dry run.

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
HQ_GIT_DIR="$HQ_ROOT/.git"
MIRROR_ROOT="${HQ_SYNC_MIRROR_ROOT:-$HOME/.hq/hq-root-git}"
MIRROR_MARKER="hq-sync-mirror-disabled.json"
# Same lock directory as hq-autocommit.sh and hq-storage.sh.
AUTOSAVE_LOCK_DIR="${TMPDIR:-/tmp}/hq-autocommit.lock"
AUTOSAVE_STALE_DAYS="${HQ_AUTOSAVE_STALE_DAYS:-7}"
case "$AUTOSAVE_STALE_DAYS" in ''|*[!0-9]*) AUTOSAVE_STALE_DAYS=7 ;; esac
APPLY=0
CONFIRMED=0
LOCK_HELD=0

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
on_exit() {
  cleanup_session_lists
  release_autosave_lock
}
trap on_exit EXIT

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
  sed -n '2,35p' "$0"
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

# human_kb <kb> / human_bytes <bytes>
human_kb() {
  awk -v kb="${1:-0}" 'BEGIN {
    if (kb >= 1048576) printf "%.1f GB", kb / 1048576
    else if (kb >= 1024) printf "%.1f MB", kb / 1024
    else printf "%d KB", kb }'
}
human_bytes() {
  local b="${1:-0}"
  case "$b" in ''|*[!0-9]*) b=0 ;; esac
  human_kb "$((b / 1024))"
}

# Sizes one scan area into <out>, one `du -sk` line per top-level entry. Each
# entry is its own du process, so the lines already written survive a
# timeout and give a lower bound for a tree too big to finish.
size_area() {
  local path="$1" out="$2" c rc=0
  : >"$out"
  if [ ! -d "$path" ]; then
    du -sk "$path" >>"$out" 2>/dev/null || rc=1
    return "$rc"
  fi
  for c in "$path"/* "$path"/.[!.]* "$path"/..?*; do
    [ -L "$c" ] && continue
    [ -e "$c" ] || continue
    du -sk "$c" >>"$out" 2>/dev/null || rc=1
  done
  return "$rc"
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
    "$HQ_GIT_DIR"
    "$HOME/.hq"
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
    hq_git_scan_notes
    return 0
  fi

  # Probe the fixed allowlist concurrently. One slow or unreadable tree must
  # not suppress results from the others, and the table stays at ten rows.
  for path in "${paths[@]}"; do
    out="$tmp/$i.out"
    if [ ! -e "$path" ]; then
      printf '0\tmissing\t%s\n' "$path" >"$tmp/$i.result"
      pids[$i]=""
      i=$((i + 1))
      continue
    fi
    (
      # Exit with a status, not by signal, so bash prints no "Terminated" notice.
      trap 'exit 143' TERM
      if size_area "$path" "$out"; then
        : >"$tmp/$i.done"
      else
        : >"$tmp/$i.failed"
      fi
    ) 2>/dev/null &
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
      # Stop the running du first so it does not outlive the scan.
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
    fi
    i=$((i + 1))
  done
  sleep 0.1
  i=0
  for path in "${paths[@]}"; do
    pid="${pids[$i]:-}"
    if [ -n "$pid" ]; then
      if kill -0 "$pid" 2>/dev/null; then
        pkill -KILL -P "$pid" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
      fi
      { wait "$pid"; } 2>/dev/null || true
    fi
    i=$((i + 1))
  done

  i=0
  for path in "${paths[@]}"; do
    size="$(awk '$1 ~ /^[0-9]+$/ { s += $1; n++ } END { if (n) print s }' "$tmp/$i.out" 2>/dev/null)"
    case "$size" in ''|*[!0-9]*) size="" ;; esac
    if [ -f "$tmp/$i.result" ]; then
      :
    elif [ -f "$tmp/$i.timeout" ] && [ -n "$size" ] && [ "$size" != 0 ]; then
      # A killed child makes size_area return failure and also write .failed.
      # Timeout wins so a half-measured tree stays a lower bound, not "ok".
      printf '%s\tpartial\t%s\n' "$size" "$path" >"$tmp/$i.result"
    elif [ -f "$tmp/$i.timeout" ]; then
      printf '0\ttimeout\t%s\n' "$path" >"$tmp/$i.result"
    elif [ -f "$tmp/$i.done" ] || { [ -f "$tmp/$i.failed" ] && [ -n "$size" ]; }; then
      # A partly unreadable tree still reports what du could read.
      printf '%s\tok\t%s\n' "${size:-0}" "$path" >"$tmp/$i.result"
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
      if ($2 == "ok") shown = human($1)
      else if ($2 == "partial") shown = ">=" human($1)
      else if ($2 == "missing") shown = "0 KB"
      else shown = "unknown"
      printf "%10s  %-9s  %s\n", shown, $2, $3
    }'
  rm -rf -- "$tmp"
  echo "partial = timed out; the size is a lower bound from the entries measured in time."
  hq_git_scan_notes
}

# ------------------------- HQ root git and sync mirror ----------------------

hq_git() { git --git-dir="$HQ_GIT_DIR" "$@"; }
has_hq_git() { [ -d "$HQ_GIT_DIR/objects" ]; }

# Prints "loose_count loose_kb pack_kb garbage_kb" from count-objects -v.
hq_git_counts() {
  hq_git count-objects -v 2>/dev/null | awk -F': ' '
    $1 == "count" { c = $2 } $1 == "size" { s = $2 } $1 == "size-pack" { p = $2 } $1 == "size-garbage" { g = $2 }
    END { printf "%d %d %d %d\n", c, s, p, g }'
}

hq_git_summary() {
  local counts c s p g
  counts=$(hq_git_counts)
  read -r c s p g <<EOF
$counts
EOF
  echo "hq-git $HQ_GIT_DIR loose_objects=$c loose=$(human_kb "$s") packed=$(human_kb "$p") garbage=$(human_kb "$g")"
}

# Warns when the newest autosave commit on HEAD is older than the stale window.
autosave_staleness() {
  local ct now_s age day
  ct=$(hq_git log -1 --format=%ct --grep='^autosave(' HEAD 2>/dev/null) || ct=""
  case "$ct" in
    ''|*[!0-9]*)
      echo "autosave last_commit=none"
      return 0
      ;;
  esac
  now_s=$(date +%s)
  case "$now_s" in ''|*[!0-9]*) return 0 ;; esac
  age=$(( (now_s - ct) / 86400 ))
  day=$(date -r "$ct" +%Y-%m-%d 2>/dev/null || date -d "@$ct" +%Y-%m-%d 2>/dev/null)
  if [ "$age" -ge "$AUTOSAVE_STALE_DAYS" ]; then
    echo "warn autosave-stale last_commit=$day age_days=$age: HQ autosave has not committed in $age days. If loose objects keep growing, autosave is writing files into git without committing them. Run prune-hq-history and report it with /hq-bug."
  else
    echo "autosave last_commit=$day age_days=$age"
  fi
}

# Directories directly under the mirror root that sync has disabled.
disabled_mirrors() {
  local d
  [ -d "$MIRROR_ROOT" ] || return 0
  for d in "$MIRROR_ROOT"/*/; do
    d="${d%/}"
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    [ -f "$d/$MIRROR_MARKER" ] && printf '%s\n' "$d"
  done
  return 0
}

active_mirrors() {
  local d
  [ -d "$MIRROR_ROOT" ] || return 0
  for d in "$MIRROR_ROOT"/*/; do
    d="${d%/}"
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    [ -f "$d/$MIRROR_MARKER" ] || printf '%s\n' "$d"
  done
  return 0
}

# marker_field <file> <name>: a string or number field from the marker JSON.
# A JSON null reads as empty, so "disabled_at": null is not disabled.
marker_field() {
  local v
  v=$(sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" 2>/dev/null | head -1)
  v="${v%"${v##*[![:space:]]}"}"
  [ "$v" = null ] && v=""
  printf '%s\n' "$v"
}

mirror_marker_line() {
  local d="$1" m="$1/$MIRROR_MARKER" measured cap
  measured=$(marker_field "$m" measured_bytes)
  cap=$(marker_field "$m" cap_bytes)
  echo "disabled-mirror $d disabled_at=$(marker_field "$m" disabled_at) reason=$(marker_field "$m" reason) measured=$(human_bytes "$measured") cap=$(human_bytes "$cap")"
}

MIRROR_NOTE="note: every commit in this recovery copy exists in $HQ_GIT_DIR, so its objects are usually the same ones, often as hard links (or APFS clones, which du counts twice). While it exists, pruning the HQ root alone frees almost nothing: the space comes back only when both copies are gone."

# The git dir inside a recovery copy: <dir>/.git when present, else <dir>.
recovery_git_dir() {
  if [ -e "$1/.git" ]; then printf '%s\n' "$1/.git"; else printf '%s\n' "$1"; fi
}

# recovery_refs_in_hq <dir>: 0 when every commit reachable from the recovery
# copy's refs, HEAD and reflogs exists in the HQ root's git; 1 (prints the
# first missing commit sha) when one is missing; 2 when the copy cannot be
# read, has no commits, or any read fails; 3 when the HQ root is shallow (its
# history is incomplete, so presence there proves nothing); 4 (prints the
# first missing sha) when any object in the copy, referenced or not, is
# missing from the HQ root. Only 0 makes the copy a candidate.
recovery_refs_in_hq() {
  local gd commits head checked line objs
  has_hq_git || return 2
  case "$(hq_git rev-parse --is-shallow-repository 2>/dev/null)" in
    false) ;;
    true) return 3 ;;
    *) return 2 ;;
  esac
  gd=$(recovery_git_dir "$1")
  git --git-dir="$gd" rev-parse --git-dir >/dev/null 2>&1 || return 2
  head=""
  if git --git-dir="$gd" rev-parse -q --verify HEAD >/dev/null 2>&1; then head=HEAD; fi
  commits=$(git --git-dir="$gd" rev-list --all --reflog $head 2>/dev/null) || return 2
  [ -n "$commits" ] || return 2
  checked=$(printf '%s\n' "$commits" | hq_git cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null) || return 2
  [ "$(printf '%s\n' "$checked" | wc -l)" -eq "$(printf '%s\n' "$commits" | wc -l)" ] || return 2
  while IFS= read -r line; do
    case "$line" in
      *" commit") ;;
      *" missing") printf '%s\n' "${line%% *}"; return 1 ;;
      *) return 2 ;;
    esac
  done <<EOF
$checked
EOF
  # Objects no ref points to (a dangling commit, a lone blob, staged work)
  # are not in rev-list, so every object in the copy must exist in the HQ root.
  objs=$(git --git-dir="$gd" cat-file --batch-all-objects --batch-check='%(objectname)' 2>/dev/null) || return 2
  [ -n "$objs" ] || return 2
  checked=$(printf '%s\n' "$objs" | hq_git cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null) || return 2
  [ "$(printf '%s\n' "$checked" | wc -l)" -eq "$(printf '%s\n' "$objs" | wc -l)" ] || return 2
  line=$(printf '%s\n' "$checked" | awk '$2 == "missing" { print $1; exit }')
  if [ -n "$line" ]; then printf '%s\n' "$line"; return 4; fi
  return 0
}

# recovery_worktree_state <dir>: prints a reason and returns 0 when a non-bare
# copy has an index or working-tree changes; returns 1 for a bare copy.
recovery_worktree_state() {
  local gd="$1/.git" st
  [ -e "$gd" ] || return 1
  if [ -e "$gd/index" ]; then echo "non-bare-copy-has-index"; return 0; fi
  st=$(git --git-dir="$gd" --work-tree="$1" status --porcelain --untracked-files=all 2>/dev/null) || { echo "non-bare-copy-unreadable"; return 0; }
  if [ -n "$st" ]; then echo "non-bare-copy-has-changes"; return 0; fi
  return 1
}

# Cheap HQ-git and mirror findings for scan: no history walk, no du.
hq_git_scan_notes() {
  local d found=0
  echo "hq git and sync mirror:"
  if has_hq_git; then
    hq_git_summary
    autosave_staleness
  else
    echo "hq-git $HQ_GIT_DIR missing"
  fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    mirror_marker_line "$d"
    found=1
  done <<EOF
$(disabled_mirrors)
EOF
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    echo "active-mirror $d (in use by HQ sync; not offered for removal)"
  done <<EOF
$(active_mirrors)
EOF
  if [ "$found" = 1 ]; then
    echo "note: these are HQ sync recovery copies; trash-disabled-mirror offers one only when every object in it (commits from refs, HEAD and reflogs, and unreferenced objects) exists in $HQ_GIT_DIR"
    echo "offer: trash-disabled-mirror, then prune-hq-history"
  elif has_hq_git; then
    echo "offer: prune-hq-history when loose is large"
  fi
}

# Prints "count disk_bytes" for loose objects `git prune` would delete.
unreachable_loose() {
  local list
  list=$(hq_git prune -n --expire=1.hour.ago 2>/dev/null) || return 1
  if [ -z "$list" ]; then
    echo "0 0"
    return 0
  fi
  printf '%s\n' "$list" | awk '{ print $1 }' \
    | hq_git cat-file --batch-check='%(objectsize:disk)' 2>/dev/null \
    | awk '$1 ~ /^[0-9]+$/ { s += $1; n++ } END { printf "%d %d\n", n, s }'
}

# "total_bytes linked_bytes": regular files under <dir>, and those with more
# than one hard link (shared with another git store).
mirror_link_bytes() {
  find "$1" -type f -print0 2>/dev/null | LC_ALL=C perl -0ne '
    chomp; my @st = lstat($_) or next; $t += $st[7]; $l += $st[7] if $st[3] > 1;
    END { printf "%d %d\n", $t, $l }'
}

take_autosave_lock() {
  mkdir "$AUTOSAVE_LOCK_DIR" 2>/dev/null || return 1
  LOCK_HELD=1
  printf 'pid=%s\n' "$$" >"$AUTOSAVE_LOCK_DIR/owner" 2>/dev/null || true
}

release_autosave_lock() {
  [ "$LOCK_HELD" = 1 ] || return 0
  rm -f -- "$AUTOSAVE_LOCK_DIR/owner" 2>/dev/null || true
  rmdir "$AUTOSAVE_LOCK_DIR" 2>/dev/null || true
  LOCK_HELD=0
}

refuse_unconfirmed() {
  echo "refused: $1 changes data. Show the dry run to the user, and re-run with --apply --yes only after an explicit yes."
  exit 3
}

# Alternates files on the known HQ locations (repos and worktrees under the
# HQ root, and the HQ sync recovery copies) whose entry names the HQ root's
# git. Prints the borrowing repo for each. Skips the HQ root's own file.
hq_root_borrowers() {
  local f self
  self="$HQ_GIT_DIR/objects/info/alternates"
  {
    find "$HQ_ROOT" -path "$HQ_GIT_DIR" -prune -o -name node_modules -prune -o \
      -path '*/objects/info/alternates' -type f -print 2>/dev/null
    if [ -d "$MIRROR_ROOT" ]; then
      find "$MIRROR_ROOT" -maxdepth 5 -path '*/objects/info/alternates' -type f -print 2>/dev/null
    fi
  } | while IFS= read -r f; do
    [ "$f" = "$self" ] && continue
    if alternates_lists_mirror "$f" "$HQ_GIT_DIR"; then
      printf '%s\n' "${f%/objects/info/alternates}"
    fi
  done
}

cmd_prune_hq_history() {
  local before res n bytes held d borrowers
  if ! has_hq_git; then
    echo "hq-git $HQ_GIT_DIR missing; nothing to prune"
    return 0
  fi
  if [ "$APPLY" = 1 ]; then echo "mode=apply"; else echo "mode=dry-run"; fi
  if [ "$APPLY" = 1 ] && [ "$CONFIRMED" != 1 ]; then refuse_unconfirmed prune-hq-history; fi
  hq_git_summary
  autosave_staleness
  if ! res=$(unreachable_loose); then
    echo "error: git prune -n failed on $HQ_GIT_DIR; nothing changed"
    exit 1
  fi
  read -r n bytes <<EOF
$res
EOF
  if borrowers=$(hq_root_borrowers) && [ -n "$borrowers" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && echo "kept $HQ_GIT_DIR reason=borrowed-by $d: this repo reads objects from the HQ root through objects/info/alternates; pruning could break it"
    done <<EOF
$borrowers
EOF
    echo "refused: prune-hq-history does not run while another repo borrows the HQ root's objects. Run 'git repack -a -d' in that repo and remove its alternates entry first."
    exit 3
  fi
  held=$(disabled_mirrors)
  [ -z "$held" ] || echo "note: a disabled HQ sync recovery copy may share objects with $HQ_GIT_DIR; trash-disabled-mirror checks its refs first"
  if [ "$APPLY" != 1 ]; then
    echo "would-prune objects=$n disk=$(human_bytes "$bytes") disk_bytes=$bytes"
    return 0
  fi
  if [ "$n" = 0 ]; then
    echo "pruned objects=0 disk_bytes=0"
    return 0
  fi
  if ! take_autosave_lock; then
    echo "kept $HQ_GIT_DIR reason=autosave-lock-held ($AUTOSAVE_LOCK_DIR); try again shortly"
    exit 3
  fi
  before=$(free_kb)
  if ! hq_git prune --expire=1.hour.ago; then
    echo "error: git prune failed on $HQ_GIT_DIR"
    exit 1
  fi
  release_autosave_lock
  echo "pruned objects=$n disk=$(human_bytes "$bytes") disk_bytes=$bytes"
  hq_git_summary
  report_freed "$before"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    echo "still-held-by $d: run trash-disabled-mirror to free this space"
  done <<EOF
$held
EOF
}

# Moves <path> to the user's Trash and prints where it went. Never deletes.
trash_path() {
  local p="$1" name dest tdir
  name="hq-sync-mirror-$(basename "$p")-$(date +%Y%m%d%H%M%S)"
  if [ -n "${HQ_FREE_DISK_TRASH_DIR:-}" ]; then
    tdir="$HQ_FREE_DISK_TRASH_DIR"
  elif [ "$(uname -s)" = Darwin ]; then
    tdir="$HOME/.Trash"
  else
    if command -v gio >/dev/null 2>&1 && gio trash -- "$p" 2>/dev/null; then
      echo "Trash (gio)"
      return 0
    fi
    tdir="${XDG_DATA_HOME:-$HOME/.local/share}/Trash/files"
  fi
  dest="$tdir/$name"
  if mkdir -p "$tdir" 2>/dev/null && mv -- "$p" "$dest" 2>/dev/null; then
    echo "$dest"
    return 0
  fi
  # macOS privacy controls can block writes to ~/.Trash from a terminal.
  # Finder can still move the folder there.
  if [ -z "${HQ_FREE_DISK_TRASH_DIR:-}" ] && [ "$(uname -s)" = Darwin ] && command -v osascript >/dev/null 2>&1; then
    if osascript -e 'on run argv' -e 'tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)' -e 'end run' "$p" >/dev/null 2>&1; then
      echo "Trash (Finder)"
      return 0
    fi
  fi
  return 1
}

# An alternates entry is one path per line (git ignores blanks and # comments).
# Keep the mirror only when a whole line is that mirror or its objects dir.
# A longer path that merely contains the mirror string is not a borrow.
alternates_lists_mirror() {
  local alt="$1" d="$2" line p dreal
  [ -f "$alt" ] || return 1
  dreal=$(cd "$d" 2>/dev/null && pwd -P) || dreal=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      "$d"|"$d/"|"$d/objects"|"$d/objects/") return 0 ;;
    esac
    # Compare resolved real paths too: a relative entry (relative to the HQ
    # root's objects dir) or one spelled through a symlink names the same copy.
    case "$line" in /*) p="$line" ;; *) p="$(dirname "$alt")/../$line" ;; esac
    p=$(cd "$p" 2>/dev/null && pwd -P) || continue
    [ -n "$dreal" ] || continue
    case "$p" in "$dreal"|"$dreal/objects") return 0 ;; esac
  done <"$alt"
  return 1
}

cmd_trash_disabled_mirror() {
  local d any=0 res total linked dest alt rc miss
  if [ "$APPLY" = 1 ]; then echo "mode=apply"; else echo "mode=dry-run"; fi
  if [ "$APPLY" = 1 ] && [ "$CONFIRMED" != 1 ]; then refuse_unconfirmed trash-disabled-mirror; fi
  [ "$APPLY" = 1 ] && collect_session_cwds
  alt="$HQ_GIT_DIR/objects/info/alternates"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    any=1
    mirror_marker_line "$d"
    if [ -z "$(marker_field "$d/$MIRROR_MARKER" disabled_at)" ]; then
      echo "kept $d reason=marker-without-disabled_at"
      continue
    fi
    if alternates_lists_mirror "$alt" "$d"; then
      echo "kept $d reason=hq-git-borrows-objects (listed in $alt)"
      continue
    fi
    rc=0
    miss=$(recovery_refs_in_hq "$d") || rc=$?
    if [ "$rc" = 1 ]; then
      echo "kept $d reason=commit-missing-from-hq-root ($miss): this is an HQ sync recovery copy holding history the HQ root lacks"
      continue
    elif [ "$rc" = 4 ]; then
      echo "kept $d reason=object-missing-from-hq-root ($miss): this recovery copy holds an object (possibly unreferenced) the HQ root lacks"
      continue
    elif [ "$rc" = 3 ]; then
      echo "kept $d reason=hq-root-shallow: $HQ_GIT_DIR is a shallow clone, so it cannot prove it holds this recovery copy's history"
      continue
    elif [ "$rc" != 0 ]; then
      echo "kept $d reason=refs-unreadable: cannot confirm the HQ root holds this recovery copy's history"
      continue
    fi
    if miss=$(recovery_worktree_state "$d"); then
      echo "kept $d reason=$miss: a non-bare recovery copy with an index or working-tree changes may hold uncommitted work"
      continue
    fi
    echo "refs-covered $d: every object in it (commits from refs, HEAD and reflogs, and unreferenced objects) exists in $HQ_GIT_DIR"
    if [ "$APPLY" = 1 ] && path_in_list "$LIVE_PROC_CWDS" "$d" "$(cd "$d" 2>/dev/null && pwd -P)"; then
      echo "kept $d reason=live-process"
      continue
    fi
    res=$(mirror_link_bytes "$d")
    read -r total linked <<EOF
$res
EOF
    echo "mirror-size $d size=$(human_bytes "$total") hard_linked=$(human_bytes "$linked") size_bytes=$total hard_linked_bytes=$linked"
    echo "$MIRROR_NOTE"
    if [ "$APPLY" != 1 ]; then
      echo "would-trash $d"
      continue
    fi
    if dest=$(trash_path "$d"); then
      echo "trashed $d -> $dest"
    else
      echo "kept $d reason=trash-failed"
    fi
  done <<EOF
$(disabled_mirrors)
EOF
  if [ "$any" = 0 ]; then
    echo "no disabled HQ sync mirror under $MIRROR_ROOT"
  elif [ "$APPLY" = 1 ]; then
    echo "The space comes back when the Trash is emptied, and after prune-hq-history if the HQ root still holds unreachable objects."
  fi
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
    --yes) CONFIRMED=1; shift ;;
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
  prune-hq-history) cmd_prune_hq_history ;;
  trash-disabled-mirror) cmd_trash_disabled_mirror ;;
  *) usage; exit 2 ;;
esac
