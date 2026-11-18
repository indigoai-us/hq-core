#!/usr/bin/env bash
# hq-core: public
# safe-store.sh — shared file-safety helper for small stores that hooks and
# scripts keep under a private folder (held reminders, ledgers, snapshot
# reads). Source it; it only defines functions.
#
#   . "$HQ_ROOT/core/scripts/lib/safe-store.sh"
#   hq_store_mkdir "$dir" || echo "refused: $HQ_STORE_REASON" >&2
#   printf '%s\n' "$row" | hq_store_append "$dir" ledger.tsv
#
# Entries left on disk beforehand are refused before anything is opened,
# written, renamed or removed: a symlink, dangling symlink, hard link, FIFO,
# device or folder at a store file; a symlink at a store folder; a store folder
# or file owned by another user or writable by group or others. Temporary
# names are random and created exclusively. Every function finishes the store
# folder checks (owner, mode, not a symlink, same folder after cd) before any
# open, redirect, mkdir, rmdir, rm or mv, so a refused call changes nothing on
# disk. hq_store_quarantine renames a refused entry aside; nothing inside a
# refused folder is removed.
#
# Return codes (every function; none exits the caller, with or without set -e):
#   0  done or accepted
#   1  refused: a check failed; nothing was written, moved or removed
#   2  absent: the store folder or entry does not exist
#   3  done, but a check after the action found the folder path or the entry
#      replaced while it ran; the action went to the folder that was checked
#   4  the action failed after the checks passed (I/O error, folder not empty)
# HQ_STORE_REASON holds one line for codes 1 to 4. hq_store_claim and
# hq_store_quarantine set HQ_STORE_PATH to the folder they made. Both are set
# in the shell that calls the function: in "producer | hq_store_append ..."
# the function runs in a pipeline subshell and the caller sees neither (the
# return code still arrives). Feed stdin with a redirect or here-string when
# the reason matters.
#
# Paths: a trailing "/" is removed, and a folder path whose last part is ".",
# ".." or empty is refused, so a symlink cannot pass as "link/" or "link/.".
#
# Processes started:
#   none (builtins only): hq_store_name_ok, hq_store_preflight
#   one stat: hq_store_dir_ok, hq_store_file_ok
#   stat (parent), mkdir, stat: hq_store_mkdir
#   one subshell plus, per call (the first stat checks the store folder):
#     hq_store_append        stat (two), cat
#     hq_store_write_atomic  stat (three to five), mktemp, cat, mv
#     hq_store_read          stat (two)
#     hq_store_remove        stat (two), rm
#     hq_store_rename        stat (three or four), mv
#     hq_store_rmdir         stat (two), rmdir
#     hq_store_claim         stat (three), mktemp, mv
#     hq_store_quarantine    stat, mktemp, mv
#   The first stat use in a shell runs one extra stat to tell GNU from BSD and
#   one "mv --version" to pick the mv flag.
#
# How the folder is held: each acting function runs in a subshell that enters
# the folder with cd, then checks that "." and the folder path are the same
# folder and that the path is not a symlink. Every later step uses names
# relative to ".", so a folder swapped in at the path after the check does not
# redirect the action, and a check after the action reports the swap with 3.
# A file is opened once, and the open descriptor is checked (regular file,
# owner, one link, mode, same inode as the name) before a byte is written or
# read.
#
# Remaining window. Bash cannot open with O_NOFOLLOW or relative to a held
# descriptor. A process of the same user that swaps an entry inside the held
# folder between the builtin checks and the open can make that open follow a
# symlink, and an append or temporary-file open through a dangling symlink
# swapped in at that instant creates the empty target; the descriptor check
# then refuses before any data moves. A FIFO swapped in at that instant can
# make an append or read open wait for a writer or reader; the temporary file
# of hq_store_write_atomic is opened read-write, which does not wait. mv runs
# with -T (GNU) or -h (BSD and macOS), so a symlink to a folder swapped in at
# the target is replaced, not followed; where neither flag exists (for
# example BusyBox) plain mv runs and such a link would receive the file. A
# real folder swapped in at the target receives the file under -h or plain mv
# and stays inside the store; -T refuses it. The check after the action
# reports either case. Writes are not fsynced. hq_store_preflight is a
# builtin, point-in-time check of the path and does not read modes or link
# counts.
#
# Windows (Git Bash): the same code runs. MSYS derives owner and mode from the
# Windows ACL, so those checks carry less weight there, and the descriptor
# check needs /dev/fd. A check that cannot run refuses.
#
# Bash 3.2 compatible.

[ -z "${_HQ_SAFE_STORE_SH:-}" ] || return 0 2>/dev/null || exit 0
_HQ_SAFE_STORE_SH=1
HQ_STORE_REASON=""
HQ_STORE_PATH=""
_HQ_STORE_NL='
'

# Test seam: called with <operation> <stage> right before each action, inside
# the held folder. A test redefines it to swap entries at that instant.
_hq_store_test_point() { :; }

# hq_store_name_ok <name> — one path component a caller may pass as <name>:
# not empty, "." or "..", no "/", "\", "..", ":" (a Windows stream name),
# control character (newline, carriage return, tab) or leading "-", and at
# most 255 bytes. Builtins only.
hq_store_name_ok() {
  local name="${1-}"
  case "$name" in
    ''|.|..|-*|*/*|*\\*|*..*|*:*|*[[:cntrl:]]*)
      HQ_STORE_REASON="the store name is empty or holds a path separator, '..', ':', a leading '-' or a control character"
      return 1
      ;;
  esac
  if [ "${#name}" -gt 255 ]; then
    HQ_STORE_REASON="the store name is longer than 255 bytes"
    return 1
  fi
  return 0
}

# _hq_store_trim <path> — sets _HQ_P to <path> without trailing "/". Refuses a
# path that is empty, "/", or ends in "." or "..": with those, [ -L ] tests
# what a symlink points at, not the link.
_hq_store_trim() {
  local p="${1-}"
  while :; do
    case "$p" in
      ?*/) p="${p%/}" ;;
      *) break ;;
    esac
  done
  case "$p" in
    ''|/|.|..|*/.|*/..)
      HQ_STORE_REASON="the store path is empty or ends in '.', '..' or '/'"
      return 1
      ;;
  esac
  _HQ_P="$p"
  return 0
}

# _hq_store_dir_builtin <path> <label> — builtin checks of one folder.
_hq_store_dir_builtin() {
  if [ -L "$1" ]; then
    HQ_STORE_REASON="$2 is a symlink"
    return 1
  fi
  if [ ! -e "$1" ]; then
    HQ_STORE_REASON="$2 does not exist"
    return 2
  fi
  if [ ! -d "$1" ]; then
    HQ_STORE_REASON="$2 is not a folder"
    return 1
  fi
  if [ ! -O "$1" ]; then
    HQ_STORE_REASON="$2 is owned by another user"
    return 1
  fi
  return 0
}

# _hq_store_file_builtin <path> <label> — builtin checks of one file. A FIFO,
# device or folder fails -f, so nothing that could block is opened.
_hq_store_file_builtin() {
  if [ -L "$1" ]; then
    HQ_STORE_REASON="$2 is a symlink"
    return 1
  fi
  if [ ! -e "$1" ]; then
    HQ_STORE_REASON="$2 does not exist"
    return 2
  fi
  if [ ! -f "$1" ]; then
    HQ_STORE_REASON="$2 is not a regular file"
    return 1
  fi
  if [ ! -O "$1" ]; then
    HQ_STORE_REASON="$2 is owned by another user"
    return 1
  fi
  return 0
}

# hq_store_preflight <root> <file> — builtins only (-L, -e, -d, -f, -O), so a
# caller on a hot path starts no process. <file> must sit under <root>.
# <root> and every folder below it down to <file> must be a real folder (not a
# symlink) owned by this user, and <file> a regular file (not a symlink)
# owned by this user. Returns 0, 1 (refused) or 2 (a part does not exist).
# Modes and link counts are not read; use hq_store_read or hq_store_file_ok
# before trusting content.
hq_store_preflight() {
  local root="${1-}" file="${2-}" rel comp cur rc
  HQ_STORE_REASON=""
  if [ -z "$root" ] || [ -z "$file" ]; then
    HQ_STORE_REASON="the store root or file is empty"
    return 1
  fi
  _hq_store_trim "$root" || return 1
  root="$_HQ_P"
  case "$file" in
    "$root"/?*) rel="${file#"$root"/}" ;;
    *)
      HQ_STORE_REASON="the store file is not under the store root"
      return 1
      ;;
  esac
  _hq_store_dir_builtin "$root" "the store root"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  cur="$root"
  while :; do
    case "$rel" in
      */*)
        comp="${rel%%/*}"
        rel="${rel#*/}"
        ;;
      *)
        comp="$rel"
        rel=""
        ;;
    esac
    case "$comp" in
      ''|.|..)
        HQ_STORE_REASON="the store path has an empty, '.' or '..' part"
        return 1
        ;;
    esac
    cur="$cur/$comp"
    if [ -z "$rel" ]; then
      _hq_store_file_builtin "$cur" "the store file"
      return $?
    fi
    _hq_store_dir_builtin "$cur" "a store folder"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
  done
}

# _hq_store_stat_flavor — GNU or BSD stat, and the mv flag that keeps mv from
# following a symlink at the target (GNU -T, BSD -h), decided once per shell.
_hq_store_stat_flavor() {
  [ -z "${_HQ_STORE_STAT:-}" ] || return 0
  if command stat -c %h / >/dev/null 2>&1; then
    _HQ_STORE_STAT=gnu
  elif command stat -f %l / >/dev/null 2>&1; then
    _HQ_STORE_STAT=bsd
  else
    _HQ_STORE_STAT=none
  fi
  if command mv --version >/dev/null 2>&1; then
    _HQ_STORE_MV="-T"
  else
    case "${OSTYPE:-}" in
      darwin*|freebsd*) _HQ_STORE_MV="-h" ;;
      *) _HQ_STORE_MV="" ;;
    esac
  fi
  return 0
}

# _hq_store_mv <from> <to> — mv -f with the no-follow target flag when known.
_hq_store_mv() {
  command mv -f ${_HQ_STORE_MV:+"$_HQ_STORE_MV"} -- "$1" "$2" 2>/dev/null
}

# _hq_store_stat [-L] <path>... — one line "<inode> <links> <mode>" per path.
# Without -L a symlink is not followed.
_hq_store_stat() {
  local follow=""
  if [ "${1-}" = "-L" ]; then
    follow="-L"
    shift
  fi
  case "${_HQ_STORE_STAT:-}" in
    gnu) command stat $follow -c '%i %h %a' -- "$@" 2>/dev/null ;;
    bsd) command stat $follow -f '%i %l %Lp' -- "$@" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# _hq_store_parse <line> — sets _HQ_S_INO, _HQ_S_LINKS, _HQ_S_MODE.
_hq_store_parse() {
  local line="${1-}" rest
  line="${line%$'\r'}"
  _HQ_S_INO="${line%% *}"
  rest="${line#* }"
  _HQ_S_LINKS="${rest%% *}"
  _HQ_S_MODE="${rest#* }"
  case "$_HQ_S_INO" in ''|*[!0-9]*) return 1 ;; esac
  case "$_HQ_S_LINKS" in ''|*[!0-9]*) return 1 ;; esac
  case "$_HQ_S_MODE" in
    [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) return 0 ;;
  esac
  return 1
}

# _hq_store_mode_private <mode> — 0 when neither group nor others may write.
_hq_store_mode_private() {
  local m="${1-}" g o
  m="${m#"${m%???}"}"
  g="${m#?}"
  g="${g%?}"
  o="${m#??}"
  case "$g" in [2367]) return 1 ;; esac
  case "$o" in [2367]) return 1 ;; esac
  return 0
}

# _hq_store_check_lines <stat-lines> <label>:<kind>... — check one stat line
# per label, in order. Kinds:
#   i  record the inode as the reference (an open descriptor)
#   s  same inode as the reference
#   d  not writable by group or others (a folder)
#   D  same inode as the reference, and d
#   f  not writable by group or others, and one link (a file)
#   c  same inode as the reference, and f
_hq_store_check_lines() {
  local lines="$1" line label kind n=0 want ref=""
  local -a specs
  shift
  specs=("$@")
  want=$#
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    [ "$n" -le "$want" ] || break
    label="${specs[$((n - 1))]%:*}"
    kind="${specs[$((n - 1))]##*:}"
    if ! _hq_store_parse "$line"; then
      HQ_STORE_REASON="the mode or link count of $label could not be read"
      return 1
    fi
    case "$kind" in
      i)
        ref="$_HQ_S_INO"
        continue
        ;;
      s|D|c)
        if [ "$_HQ_S_INO" != "$ref" ]; then
          HQ_STORE_REASON="$label was replaced while it was open"
          return 1
        fi
        ;;
    esac
    case "$kind" in
      d|D|f|c)
        if ! _hq_store_mode_private "$_HQ_S_MODE"; then
          HQ_STORE_REASON="$label is writable by group or others"
          return 1
        fi
        ;;
    esac
    case "$kind" in
      f|c)
        if [ "$_HQ_S_LINKS" != 1 ]; then
          HQ_STORE_REASON="$label has more than one link"
          return 1
        fi
        ;;
    esac
  done <<EOF
$lines
EOF
  if [ "$n" -ne "$want" ]; then
    HQ_STORE_REASON="the mode or link count of the store could not be read"
    return 1
  fi
  return 0
}

# hq_store_dir_ok <dir> — a real folder (not a symlink), owned by this user,
# not writable by group or others. One stat process. Returns 0, 1 or 2.
hq_store_dir_ok() {
  local dir="${1-}" out rc
  HQ_STORE_REASON=""
  _hq_store_trim "$dir" || return 1
  dir="$_HQ_P"
  _hq_store_dir_builtin "$dir" "the store folder"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  _hq_store_stat_flavor
  out="$(_hq_store_stat "$dir")" || out=""
  _hq_store_check_lines "$out" "the store folder:d"
}

# hq_store_file_ok <file> — a regular file (not a symlink, FIFO, device or
# folder) with one link, owned by this user, not writable by group or others.
# One stat process. Returns 0, 1 or 2.
hq_store_file_ok() {
  local file="${1-}" out rc
  HQ_STORE_REASON=""
  _hq_store_trim "$file" || return 1
  if [ "$_HQ_P" != "$file" ]; then
    HQ_STORE_REASON="the store file path ends in '/'"
    return 1
  fi
  _hq_store_file_builtin "$file" "the store file"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  _hq_store_stat_flavor
  out="$(_hq_store_stat "$file")" || out=""
  _hq_store_check_lines "$out" "the store file:f"
}

# hq_store_mkdir <dir> — create <dir> with mode 0700 when nothing is at that
# name, then check it with hq_store_dir_ok. The parent must pass
# hq_store_dir_ok first; nothing is created under a refused parent. An
# existing folder is checked, never changed.
hq_store_mkdir() {
  local dir="${1-}" parent rc
  HQ_STORE_REASON=""
  _hq_store_trim "$dir" || return 1
  dir="$_HQ_P"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    case "$dir" in
      */*) parent="${dir%/*}" ;;
      *) parent="$PWD" ;;
    esac
    [ -n "$parent" ] || parent="/"
    hq_store_dir_ok "$parent"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      HQ_STORE_REASON="the parent folder was refused: $HQ_STORE_REASON"
      [ "$rc" -eq 2 ] && return 4
      return 1
    fi
    if ! ( umask 077 && command mkdir -- "$dir" ) 2>/dev/null; then
      if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
        HQ_STORE_REASON="the store folder could not be created"
        return 4
      fi
    fi
  fi
  hq_store_dir_ok "$dir"
}

# _hq_store_run <body> <args>... — run <body> in a subshell with umask 077 and
# errexit off; stdin and stdout pass through. Copies HQ_STORE_REASON and
# HQ_STORE_PATH back from the subshell and returns its code.
_hq_store_run() {
  local rc=0 back=""
  HQ_STORE_REASON=""
  HQ_STORE_PATH=""
  _hq_store_stat_flavor
  {
    back="$(
      (
        set +e
        umask 077
        "$@"
        rc=$?
        printf '%s\n%s' "${HQ_STORE_PATH:-}" "${HQ_STORE_REASON:-}" >&3
        exit "$rc"
      ) 3>&1 1>&4 4>&-
    )" || rc=$?
  } 4>&1
  HQ_STORE_PATH="${back%%"$_HQ_STORE_NL"*}"
  case "$back" in
    *"$_HQ_STORE_NL"*) HQ_STORE_REASON="${back#*"$_HQ_STORE_NL"}" ;;
    *) HQ_STORE_REASON="" ;;
  esac
  return "$rc"
}

# _hq_store_enter <dir> [<name>] — subshell only: hold <dir> as the working
# folder. Builtin checks of the path, cd, then "." and the path must be the
# same folder, the path must not be a symlink, and "." must be owned by this
# user and not writable by group or others (one stat). Every acting function
# calls this first, so a refused folder is never written, created in, moved
# in or removed from. Sets _HQ_DIR.
_hq_store_enter() {
  local rc out
  _hq_store_trim "${1-}" || return 1
  case "$_HQ_P" in
    *"$_HQ_STORE_NL"*)
      HQ_STORE_REASON="the store folder path holds a newline"
      return 1
      ;;
    /*|[A-Za-z]:[/\\]*) _HQ_DIR="$_HQ_P" ;;
    *) _HQ_DIR="$PWD/$_HQ_P" ;;
  esac
  if [ -n "${2-}" ]; then
    hq_store_name_ok "$2" || return 1
  fi
  _hq_store_dir_builtin "$_HQ_DIR" "the store folder"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  _hq_store_test_point enter before-cd
  if ! CDPATH='' cd -P -- "$_HQ_DIR" 2>/dev/null; then
    HQ_STORE_REASON="the store folder could not be entered"
    return 1
  fi
  _hq_store_test_point enter after-cd
  if [ -L "$_HQ_DIR" ] || [ ! . -ef "$_HQ_DIR" ] || [ ! -O . ]; then
    HQ_STORE_REASON="the store folder was replaced while it was checked"
    return 1
  fi
  # The mode of the held folder is read here, before the caller opens,
  # creates, moves or removes anything in it.
  out="$(_hq_store_stat .)" || out=""
  _hq_store_check_lines "$out" "the store folder:d" || return 1
  return 0
}

# _hq_store_still — subshell only: the folder path still names the held one.
_hq_store_still() {
  if [ -L "$_HQ_DIR" ] || [ ! . -ef "$_HQ_DIR" ]; then
    HQ_STORE_REASON="the store folder path was replaced during the operation; the action went to the folder that was checked"
    return 3
  fi
  return 0
}

# _hq_store_entry <name> — subshell only: sets _HQ_E to none, link, dir, file
# or other for ./<name>.
_hq_store_entry() {
  if [ -L "./$1" ]; then
    _HQ_E="link"
  elif [ ! -e "./$1" ]; then
    _HQ_E="none"
  elif [ -d "./$1" ]; then
    _HQ_E="dir"
  elif [ -f "./$1" ]; then
    _HQ_E="file"
  else
    _HQ_E="other"
  fi
}

# _hq_store_refuse_entry <name> — reason for an entry that is not a usable
# file. Returns 1.
_hq_store_refuse_entry() {
  case "$_HQ_E" in
    link) HQ_STORE_REASON="the store file $1 is a symlink" ;;
    dir) HQ_STORE_REASON="the store file $1 is a folder" ;;
    *) HQ_STORE_REASON="the store file $1 is not a regular file" ;;
  esac
  return 1
}

# _hq_store_fd_ok <name> — subshell only, with descriptor 5 open on ./<name>:
# the descriptor is a regular file owned by this user; ./<name> is not a
# symlink and has the same inode and one link; neither it nor "." is writable
# by group or others. One stat process.
_hq_store_fd_ok() {
  local out
  if [ ! -f /dev/fd/5 ] || [ ! -O /dev/fd/5 ] || [ -L "./$1" ] || [ ! -f "./$1" ]; then
    HQ_STORE_REASON="the store file $1 was replaced while it was opened"
    return 1
  fi
  out="$(_hq_store_stat -L /dev/fd/5 . "./$1")" || out=""
  _hq_store_check_lines "$out" "the open file:i" "the store folder:d" "the store file $1:c"
}

# _hq_store_target_ok <name> — subshell only: ./<name> is absent or a checked
# regular file, so a rename may replace it.
_hq_store_target_ok() {
  local out
  _hq_store_entry "$1"
  case "$_HQ_E" in
    none) return 0 ;;
    file) ;;
    *) _hq_store_refuse_entry "$1"; return 1 ;;
  esac
  _hq_store_file_builtin "./$1" "the store file $1" || return 1
  out="$(_hq_store_stat "./$1")" || out=""
  _hq_store_check_lines "$out" "the store file $1:f"
}

# _hq_store_moved_ok <path> — subshell only, after a rename of the file open
# on descriptor 5: <path> is not a symlink and has the descriptor's inode.
_hq_store_moved_ok() {
  local out
  if [ -L "$1" ] || [ ! -e "$1" ]; then
    return 1
  fi
  out="$(_hq_store_stat -L /dev/fd/5 "$1")" || out=""
  _hq_store_check_lines "$out" "the open entry:i" "the moved entry:s"
}

# --- append ------------------------------------------------------------------

_hq_store_append_fd() {
  _hq_store_fd_ok "$1" || return 1
  _hq_store_test_point append before-write
  if ! command cat >&5; then
    HQ_STORE_REASON="the store file $1 could not be written"
    return 4
  fi
  return 0
}

_hq_store_append_body() {
  local name="$2" rc
  _hq_store_enter "$1" "$name" || return $?
  _hq_store_test_point append before-open
  _hq_store_entry "$name"
  if [ "$_HQ_E" = none ]; then
    # Exclusive create: noclobber opens a new name with O_EXCL.
    set -C
    _hq_store_append_fd "$name" 2>/dev/null 5>"./$name"
    rc=$?
    set +C
    if [ "$rc" -eq 0 ]; then
      _hq_store_still
      return $?
    fi
    [ -z "${HQ_STORE_REASON:-}" ] || return "$rc"
    # The create lost to another writer; append to what is there now.
    _hq_store_entry "$name"
    if [ "$_HQ_E" = none ]; then
      HQ_STORE_REASON="the store file $name could not be created"
      return 4
    fi
  fi
  [ "$_HQ_E" = file ] || {
    _hq_store_refuse_entry "$name"
    return $?
  }
  _hq_store_file_builtin "./$name" "the store file $name" || return 1
  _hq_store_test_point append open-existing
  _hq_store_append_fd "$name" 2>/dev/null 5>>"./$name"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -n "${HQ_STORE_REASON:-}" ] || HQ_STORE_REASON="the store file $name could not be opened"
    return "$rc"
  fi
  _hq_store_still
}

# hq_store_append <dir> <name> — append stdin to <dir>/<name>, creating it
# 0600 with an exclusive create when absent.
hq_store_append() {
  _hq_store_run _hq_store_append_body "${1-}" "${2-}"
}

# --- write_atomic ------------------------------------------------------------

# _hq_store_tmp_drop <tmp> — descriptor 5 is open on this call's temporary
# file: remove ./<tmp> only while it is still that file (not a symlink, same
# inode), so nothing another process put at the name is removed.
_hq_store_tmp_drop() {
  if _hq_store_moved_ok "./$1"; then
    command rm -f -- "./$1" 2>/dev/null
  fi
  return 0
}

# _hq_store_write_fd <tmp> <name> — descriptor 5 is open read-write on ./<tmp>,
# which mktemp created for this call.
_hq_store_write_fd() {
  _hq_store_fd_ok "$1" || return 1
  if ! command cat >&5; then
    HQ_STORE_REASON="the temporary file could not be written"
    _hq_store_tmp_drop "$1"
    return 4
  fi
  _hq_store_test_point write_atomic before-rename "$1"
  if ! _hq_store_target_ok "$2"; then
    _hq_store_tmp_drop "$1"
    return 1
  fi
  _hq_store_test_point write_atomic before-mv
  if ! _hq_store_mv "./$1" "./$2"; then
    HQ_STORE_REASON="the store file $2 could not be replaced"
    _hq_store_tmp_drop "$1"
    return 4
  fi
  if ! _hq_store_moved_ok "./$2"; then
    HQ_STORE_REASON="the store file $2 was replaced during the rename"
    return 3
  fi
  _hq_store_still
}

_hq_store_write_atomic_body() {
  local name="$2" tmp="" template rc
  _hq_store_enter "$1" "$name" || return $?
  _hq_store_test_point write_atomic before-open
  _hq_store_target_ok "$name" || return 1
  # mktemp creates the file with O_EXCL and mode 0600 under a random name.
  template=".$name.tmp.XXXXXXXXXX"
  [ "${#template}" -le 255 ] || template=".hq-store.tmp.XXXXXXXXXX"
  tmp="$(command mktemp "./$template" 2>/dev/null)" || tmp=""
  tmp="${tmp#./}"
  case "$tmp" in
    ''|*/*|*"$_HQ_STORE_NL"*)
      HQ_STORE_REASON="the temporary file could not be created"
      return 4
      ;;
  esac
  _hq_store_test_point write_atomic before-tmp "$tmp"
  # Opened read-write without truncation: a FIFO swapped in at the name does
  # not block the open, and the descriptor check refuses anything that is not
  # this call's regular file before a byte is written.
  _hq_store_write_fd "$tmp" "$name" 2>/dev/null 5<>"./$tmp"
  rc=$?
  if [ "$rc" -ne 0 ] && [ -z "${HQ_STORE_REASON:-}" ]; then
    HQ_STORE_REASON="the temporary file could not be opened"
    rc=4
  fi
  return "$rc"
}

# hq_store_write_atomic <dir> <name> — replace <dir>/<name> with stdin: write
# a temporary file that mktemp creates in <dir> (exclusive create, 0600), then
# mv it over <name>.
hq_store_write_atomic() {
  _hq_store_run _hq_store_write_atomic_body "${1-}" "${2-}"
}

# --- read --------------------------------------------------------------------

_hq_store_read_fd() {
  # Byte semantics for read -n and ${#text}, whatever the caller's locale.
  local LC_ALL=C text=""
  _hq_store_fd_ok "$1" || return 1
  # read -d '' stops at a NUL byte with status 0, or after max+1 bytes with
  # status 0; it returns non-zero only at end of file. So status 0 means the
  # file holds a NUL byte or is over the cap.
  if IFS= read -r -d '' -n "$(($2 + 1))" text <&5; then
    if [ "${#text}" -gt "$2" ]; then
      HQ_STORE_REASON="the store file $1 is larger than $2 bytes"
    else
      HQ_STORE_REASON="the store file $1 holds a NUL byte"
    fi
    return 1
  fi
  _hq_store_still || return $?
  printf '%s' "$text"
  return 0
}

_hq_store_read_body() {
  local name="$2" max="${3-}" rc
  case "$max" in ''|*[!0-9]*|0) max=1048576 ;; esac
  _hq_store_enter "$1" "$name" || return $?
  _hq_store_test_point read before-open
  _hq_store_entry "$name"
  case "$_HQ_E" in
    none)
      HQ_STORE_REASON="the store file $name does not exist"
      return 2
      ;;
    file) _hq_store_file_builtin "./$name" "the store file $name" || return 1 ;;
    *) _hq_store_refuse_entry "$name"; return 1 ;;
  esac
  _hq_store_test_point read open
  _hq_store_read_fd "$name" "$max" 2>/dev/null 5<"./$name"
  rc=$?
  if [ "$rc" -ne 0 ] && [ -z "${HQ_STORE_REASON:-}" ]; then
    HQ_STORE_REASON="the store file $name could not be opened"
  fi
  return "$rc"
}

# hq_store_read <dir> <name> [<max-bytes>] — print <dir>/<name> as text.
# Refuses a file larger than <max-bytes> bytes (default 1 MiB, counted in
# bytes in any locale) and a file that holds a NUL byte. Prints nothing unless
# it returns 0.
hq_store_read() {
  _hq_store_run _hq_store_read_body "${1-}" "${2-}" "${3-}"
}

# --- remove, rename, rmdir ---------------------------------------------------

_hq_store_remove_body() {
  local name="$2" out
  _hq_store_enter "$1" "$name" || return $?
  _hq_store_entry "$name"
  case "$_HQ_E" in
    none)
      HQ_STORE_REASON="the store file $name does not exist"
      return 2
      ;;
    file) _hq_store_file_builtin "./$name" "the store file $name" || return 1 ;;
    *) _hq_store_refuse_entry "$name"; return 1 ;;
  esac
  out="$(_hq_store_stat . "./$name")" || out=""
  _hq_store_check_lines "$out" "the store folder:d" "the store file $name:f" || return 1
  _hq_store_test_point remove before-act
  if ! command rm -f -- "./$name" 2>/dev/null; then
    HQ_STORE_REASON="the store file $name could not be removed"
    return 4
  fi
  _hq_store_still
}

# hq_store_remove <dir> <name> — unlink <dir>/<name> when it is a regular
# single-link file owned by this user in a checked folder. Never recursive;
# anything else is refused (see hq_store_quarantine).
hq_store_remove() {
  _hq_store_run _hq_store_remove_body "${1-}" "${2-}"
}

_hq_store_rename_fd() {
  _hq_store_fd_ok "$1" || return 1
  _hq_store_target_ok "$2" || return 1
  _hq_store_test_point rename before-act
  if ! _hq_store_mv "./$1" "./$2"; then
    HQ_STORE_REASON="the store file $1 could not be renamed"
    return 4
  fi
  if ! _hq_store_moved_ok "./$2"; then
    HQ_STORE_REASON="the store file $2 was replaced during the rename"
    return 3
  fi
  _hq_store_still
}

_hq_store_rename_body() {
  local from="$2" to="$3" rc
  _hq_store_enter "$1" "$from" || return $?
  hq_store_name_ok "$to" || return 1
  _hq_store_entry "$from"
  case "$_HQ_E" in
    none)
      HQ_STORE_REASON="the store file $from does not exist"
      return 2
      ;;
    file) _hq_store_file_builtin "./$from" "the store file $from" || return 1 ;;
    *) _hq_store_refuse_entry "$from"; return 1 ;;
  esac
  _hq_store_rename_fd "$from" "$to" 2>/dev/null 5<"./$from"
  rc=$?
  if [ "$rc" -ne 0 ] && [ -z "${HQ_STORE_REASON:-}" ]; then
    HQ_STORE_REASON="the store file $from could not be opened"
  fi
  return "$rc"
}

# hq_store_rename <dir> <from> <to> — rename a checked regular file within one
# folder. <to> must be absent or a checked regular file.
hq_store_rename() {
  _hq_store_run _hq_store_rename_body "${1-}" "${2-}" "${3-}"
}

# _hq_store_child_dir_fd <name> — subshell only, with descriptor 5 open on
# ./<name>: the descriptor is a folder owned by this user, ./<name> is not a
# symlink, has the same inode, and is not writable by group or others.
_hq_store_child_dir_fd() {
  local out
  if [ -L "./$1" ] || [ ! -d /dev/fd/5 ] || [ ! -O /dev/fd/5 ]; then
    HQ_STORE_REASON="the store folder $1 was replaced while it was opened"
    return 1
  fi
  out="$(_hq_store_stat -L /dev/fd/5 . "./$1")" || out=""
  _hq_store_check_lines "$out" "the open folder:i" "the store folder:d" "the store folder $1:D"
}

_hq_store_rmdir_body() {
  local name="$2"
  _hq_store_enter "$1" "$name" || return $?
  _hq_store_entry "$name"
  case "$_HQ_E" in
    none)
      HQ_STORE_REASON="the store folder $name does not exist"
      return 2
      ;;
    dir) _hq_store_dir_builtin "./$name" "the store folder $name" || return 1 ;;
    *)
      HQ_STORE_REASON="the store entry $name is not a folder"
      return 1
      ;;
  esac
  # The child itself: owner, mode and identity, through a held descriptor.
  if ! _hq_store_child_dir_fd "$name" 2>/dev/null 5<"./$name"; then
    [ -n "${HQ_STORE_REASON:-}" ] || HQ_STORE_REASON="the store folder $name could not be opened"
    return 1
  fi
  _hq_store_test_point rmdir before-act
  if ! command rmdir -- "./$name" 2>/dev/null; then
    HQ_STORE_REASON="the store folder $name could not be removed; it may not be empty"
    return 4
  fi
  _hq_store_still
}

# hq_store_rmdir <dir> <name> — remove the empty folder <dir>/<name>. A
# symlink or a folder with entries is never removed.
hq_store_rmdir() {
  _hq_store_run _hq_store_rmdir_body "${1-}" "${2-}"
}

# --- claim and quarantine ----------------------------------------------------

# _hq_store_aside <op> <name> — subshell only: make a fresh private folder with
# mktemp -d inside the held folder and move ./<name> into it. Sets
# HQ_STORE_PATH to that folder.
_hq_store_aside() {
  local op="$1" name="$2" made=""
  made="$(command mktemp -d "./.hq-$op.XXXXXXXXXX" 2>/dev/null)" || made=""
  made="${made#./}"
  case "$made" in
    ''|*/*|*"$_HQ_STORE_NL"*)
      HQ_STORE_REASON="a private folder for the $op could not be created"
      return 4
      ;;
  esac
  if [ -L "./$made" ] || [ ! -d "./$made" ]; then
    HQ_STORE_REASON="the $op folder was replaced after it was created"
    return 1
  fi
  _hq_store_test_point "$op" before-act
  if ! _hq_store_mv "./$name" "./$made/$name"; then
    command rmdir -- "./$made" 2>/dev/null
    HQ_STORE_REASON="the store entry $name could not be moved aside"
    return 4
  fi
  HQ_STORE_PATH="$_HQ_DIR/$made"
  return 0
}

# _hq_store_claim_fd <name> <kind> — descriptor 5 is open on ./<name>.
_hq_store_claim_fd() {
  local rc
  if [ "$2" = file ]; then
    _hq_store_fd_ok "$1" || return 1
  else
    _hq_store_child_dir_fd "$1" || return 1
  fi
  _hq_store_aside claim "$1" || return $?
  if ! _hq_store_moved_ok "./${HQ_STORE_PATH##*/}/$1"; then
    HQ_STORE_REASON="the store entry $1 was replaced while it was claimed"
    return 3
  fi
  _hq_store_still
  rc=$?
  return "$rc"
}

_hq_store_claim_body() {
  local name="$2" rc
  _hq_store_enter "$1" "$name" || return $?
  _hq_store_entry "$name"
  case "$_HQ_E" in
    none)
      HQ_STORE_REASON="the store entry $name does not exist"
      return 2
      ;;
    file) _hq_store_file_builtin "./$name" "the store file $name" || return 1 ;;
    dir) _hq_store_dir_builtin "./$name" "the store folder $name" || return 1 ;;
    *) _hq_store_refuse_entry "$name"; return 1 ;;
  esac
  _hq_store_claim_fd "$name" "$_HQ_E" 2>/dev/null 5<"./$name"
  rc=$?
  if [ "$rc" -ne 0 ] && [ -z "${HQ_STORE_REASON:-}" ]; then
    HQ_STORE_REASON="the store entry $name could not be opened"
  fi
  return "$rc"
}

# hq_store_claim <dir> <name> — move <dir>/<name> (a checked regular file or
# folder) into a new private folder made with mktemp -d inside <dir>, so two
# callers cannot both take it and no guessable name is reused. On 0 (and on
# 3), HQ_STORE_PATH is that folder and the entry is HQ_STORE_PATH/<name>. The
# caller removes the claim folder with hq_store_remove and hq_store_rmdir.
hq_store_claim() {
  _hq_store_run _hq_store_claim_body "${1-}" "${2-}"
}

_hq_store_quarantine_body() {
  local name="$2"
  _hq_store_enter "$1" "$name" || return $?
  if [ ! -e "./$name" ] && [ ! -L "./$name" ]; then
    HQ_STORE_REASON="the store entry $name does not exist"
    return 2
  fi
  _hq_store_aside quarantine "$name" || return $?
  _hq_store_still
}

# hq_store_quarantine <dir> <name> — rename whatever is at <dir>/<name> (a
# refused file, folder or link) into a new private folder made with mktemp -d
# inside the checked <dir>. Nothing is opened, followed or deleted. On 0,
# HQ_STORE_PATH is that folder. Under a refused <dir> nothing is touched.
hq_store_quarantine() {
  _hq_store_run _hq_store_quarantine_body "${1-}" "${2-}"
}
