#!/usr/bin/env bash
# hq-core: public
# Shared hq CLI lookup for the lanes senior Monitor Stop gate and the lanes
# reminder shim (feedback_26faa03c). Source it; do not run it.
#
# A hook can run with a reduced PATH (a fleet agent's monitor, a GUI host)
# while the session's own shell finds hq in a user or system bin. Order: PATH,
# then a fixed list of install directories (user bins, system bins).
#
# The list is fixed on purpose. No environment variable can add a directory or
# name a binary, because a repo's .claude/settings.json `env` block can set
# environment for hooks, and these hooks execute what they find. Directories
# inside the HQ checkout ($HQ_ROOT/bin) are not searched for the same reason.
# A fallback candidate is used only when the directory and the binary (after
# following symlinks) are owned by root or the current user and are neither
# group- nor other-writable.
#
# resolve_hq_bin sets HQ_BIN and returns 0, or sets HQ_BIN="" and returns 1.
# When hq comes from a fallback directory, that directory is appended (not
# prepended) to PATH and exported: an hq installed as a `#!/usr/bin/env node`
# script can then find the node installed beside it, and the tools already on
# PATH keep precedence for every later command.

# hq_bin_path_is_safe PATH: true when PATH (symlinks followed) is owned by root
# or the current user, is not other-writable, and is not group-writable unless
# the current user owns it. Homebrew's bin (/opt/homebrew/bin, Intel
# /usr/local/bin) is owner:admin 775, so a user-owned group-writable directory
# must stay usable; a root-owned one must not be group-writable.
hq_bin_path_is_safe() {
  local p="$1" uid
  [ -e "$p" ] || return 1
  uid="$(id -u 2>/dev/null)" || return 1
  [ -n "$(find -L "$p" -maxdepth 0 \( -uid 0 -o -uid "$uid" \) -print 2>/dev/null)" ] || return 1
  [ -z "$(find -L "$p" -maxdepth 0 -perm -0002 -print 2>/dev/null)" ] || return 1
  if [ -n "$(find -L "$p" -maxdepth 0 -perm -0020 -print 2>/dev/null)" ]; then
    [ -n "$(find -L "$p" -maxdepth 0 -uid "$uid" -print 2>/dev/null)" ] || return 1
  fi
  return 0
}

resolve_hq_bin() {
  local dir dirs
  HQ_BIN="$(command -v hq 2>/dev/null || true)"
  [ -z "$HQ_BIN" ] || return 0
  dirs="${HOME:+$HOME/.local/bin:$HOME/.npm-global/bin:}/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" # HQ_BIN_DEFAULT_DIRS
  local IFS=:
  for dir in $dirs; do
    case "$dir" in /*) ;; *) continue ;; esac
    [ -f "$dir/hq" ] && [ -x "$dir/hq" ] || continue
    hq_bin_path_is_safe "$dir" && hq_bin_path_is_safe "$dir/hq" || continue
    HQ_BIN="$dir/hq"
    PATH="${PATH:+$PATH:}$dir"
    export PATH
    return 0
  done
  HQ_BIN=""
  return 1
}
