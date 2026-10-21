#!/usr/bin/env bash
# hq-core: public
# git-icon-file-check.sh — Find and remove macOS `Icon\r` files inside .git,
# then restore loose objects that went missing alongside them.
#
# Finder writes a file named `Icon` + carriage return into folders that have a
# custom icon, and iCloud Desktop & Documents sync copies them into every
# subfolder, including .git/refs and .git/objects/xx. Git then reports
# badRefName and "bad sha1 file", and when a loose object also goes missing
# every commit fails with "invalid object ... Error building trees".
# The working-tree .gitignore cannot help: .git itself is never ignored.
#
# Usage:
#   bash core/scripts/git-icon-file-check.sh [--root DIR]
#       Report `Icon\r` files under DIR/.git and index entries whose object
#       is missing. Changes nothing. Exit 0 when clean, 2 when found.
#   bash core/scripts/git-icon-file-check.sh [--root DIR] --fix
#       Delete every file named exactly `Icon\r` under DIR/.git, run
#       `git fsck`, and restore each missing blob with `git hash-object -w`
#       only when the working file hashes to exactly that object id.
#       Exit 0 when `git fsck` is clean afterwards, 2 when problems remain.
#
# DIR defaults to the HQ root. Only the exact name `Icon\r` is touched; files
# such as `Icon` or `Icons` are left alone. Both modes warn when DIR sits in
# iCloud Drive or in an iCloud-synced Desktop or Documents folder, since the
# files come back while that sync is on. Exit 1 on usage or git errors.

set -euo pipefail

ROOT=""
FIX=0
ICON_NAME="Icon"$'\r'

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

die() {
  printf 'git-icon-file-check: %s\n' "$1" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || die "--root needs a directory"; ROOT="$2"; shift 2 ;;
    --fix) FIX=1; shift ;;
    -h|--help) usage 0 ;;
    *) printf 'git-icon-file-check: unknown argument: %s\n' "$1" >&2; usage 1 ;;
  esac
done

if [ -z "$ROOT" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
[ -d "$ROOT" ] || die "not a directory: $ROOT"
ROOT="$(cd "$ROOT" && pwd -P)"

# Every git call is scoped to ROOT and allowed past the HQ-root git guard,
# which exists to stop accidental mutations, not this repair.
export HQ_ALLOW_HQ_ROOT_GIT=1
g() { git -C "$ROOT" "$@"; }

if [ -d "$ROOT/.git" ]; then
  GIT_DIR_PATH="$ROOT/.git"
elif [ -f "$ROOT/.git" ]; then
  # Linked worktree: refs and objects live in the shared (common) git dir.
  common="$(g rev-parse --git-common-dir 2>/dev/null)" || die "cannot resolve the git dir for $ROOT"
  case "$common" in
    /*) GIT_DIR_PATH="$common" ;;
    *) GIT_DIR_PATH="$ROOT/$common" ;;
  esac
  [ -d "$GIT_DIR_PATH" ] || die "git dir not found: $GIT_DIR_PATH"
  GIT_DIR_PATH="$(cd "$GIT_DIR_PATH" && pwd -P)"
else
  die "not a git repository: $ROOT"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

show() { printf '%s' "${1//$'\r'/\\r}"; }

icloud_warning() {
  local home phys_home cloud where=""
  home="${HOME:-}"
  [ -n "$home" ] && [ -d "$home" ] || return 0
  phys_home="$(cd "$home" && pwd -P)"
  cloud="$phys_home/Library/Mobile Documents/com~apple~CloudDocs"
  case "$ROOT/" in
    "$phys_home/Library/Mobile Documents/"*) where="iCloud Drive" ;;
    "$phys_home/Desktop/"*) [ -d "$cloud/Desktop" ] && where="the iCloud-synced Desktop folder" ;;
    "$phys_home/Documents/"*) [ -d "$cloud/Documents" ] && where="the iCloud-synced Documents folder" ;;
  esac
  [ -n "$where" ] || return 0
  printf 'warning: %s is inside %s.\n' "$ROOT" "$where"
  printf '  iCloud copies Icon\\r files into .git and can evict files git needs, so this repair will not hold.\n'
  printf '  Move the HQ folder outside Desktop and Documents (for example ~/hq), or turn off\n'
  printf '  "Desktop & Documents Folders" in System Settings > Apple Account > iCloud > iCloud Drive.\n'
}

# NUL-separated list of every `Icon\r` file under the git dir.
find_icons() {
  find "$GIT_DIR_PATH" -type f -name "$ICON_NAME" -print0 2>/dev/null > "$WORK/icons" || true
}

count_nul() { tr -cd '\0' < "$1" | wc -c | tr -d ' '; }

print_icons() {
  local p
  while IFS= read -r -d '' p; do
    printf '  %s\n' "$(show "${p#"$GIT_DIR_PATH"/}")"
  done < "$WORK/icons"
}

# Writes "mode sha path" lines (stage-0 entries only) for index entries whose
# object is not in the object store.
find_missing_index_objects() {
  : > "$WORK/missing-index"
  : > "$WORK/missing-shas"
  # One "mode sha path" line per stage-0 entry, gitlinks excluded (they point
  # into another repo). awk, not a shell loop: an HQ index can hold 200k+
  # entries. A path containing a newline splits into lines that fail the
  # format test below; such an entry is still checked through fsck, it just
  # cannot be matched to a working file, so it is never restored.
  g ls-files -s -z > "$WORK/index" || die "git ls-files failed in $ROOT"
  tr '\0' '\n' < "$WORK/index" | awk '
    {
      tab = index($0, "\t")
      if (tab == 0) next
      split(substr($0, 1, tab - 1), m, " ")
      if (m[1] !~ /^1[0-7]+$/ || m[2] !~ /^[0-9a-f]+$/ || m[3] != "0") next
      if (m[1] == "160000") next
      print m[1] " " m[2] " " substr($0, tab + 1)
    }' > "$WORK/index-lines"
  [ -s "$WORK/index-lines" ] || return 0
  awk '{ print $2 }' "$WORK/index-lines" | sort -u \
    | g cat-file --batch-check='%(objectname)' \
    | awk '$2 == "missing" { print $1 }' > "$WORK/missing-shas" || true
  [ -s "$WORK/missing-shas" ] || return 0
  awk 'NR == FNR { miss[$1] = 1; next } ($2 in miss)' "$WORK/missing-shas" "$WORK/index-lines" \
    > "$WORK/missing-index"
}

report() {
  local icons
  find_icons
  icons="$(count_nul "$WORK/icons")"
  find_missing_index_objects
  local missing=0
  [ -s "$WORK/missing-index" ] && missing="$(wc -l < "$WORK/missing-index" | tr -d ' ')"
  if [ "$icons" = "0" ] && [ "$missing" = "0" ]; then
    printf 'ok: no Icon\\r files under %s and no index entry is missing its object\n' "$(show "$GIT_DIR_PATH")"
    return 0
  fi
  if [ "$icons" != "0" ]; then
    printf 'found %s Icon\\r file(s) under %s:\n' "$icons" "$(show "$GIT_DIR_PATH")"
    print_icons
  fi
  if [ "$missing" != "0" ]; then
    printf 'found %s missing object(s) referenced by the index:\n' "$missing"
    awk '{ sha = $2; $1 = ""; $2 = ""; sub(/^  /, ""); printf "  %s %s\n", sha, $0 }' "$WORK/missing-index"
  fi
  printf 'Run again with --fix to delete the Icon\\r files and restore missing objects from matching working files.\n'
  return 2
}

restore_missing_objects() {
  # Candidate ids: everything fsck calls missing plus missing index objects.
  local fsck_out="$1"
  find_missing_index_objects
  {
    sed -n 's/^missing [a-z]* \([0-9a-f]\{40,64\}\).*/\1/p' "$fsck_out"
    [ -s "$WORK/missing-index" ] && awk '{ print $2 }' "$WORK/missing-index"
  } | sort -u > "$WORK/candidates" || true
  [ -s "$WORK/candidates" ] || return 0

  local sha line mode entry_sha path actual restored
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    if g cat-file -e "$sha" 2>/dev/null; then
      continue
    fi
    restored=0
    while IFS= read -r line; do
      mode="${line%% *}"; line="${line#* }"
      entry_sha="${line%% *}"; path="${line#* }"
      [ "$entry_sha" = "$sha" ] || continue
      case "$mode" in 100644|100755) ;; *) continue ;; esac
      if [ -L "$ROOT/$path" ] || [ ! -f "$ROOT/$path" ]; then
        printf '  %s: working file %s is missing; not restored\n' "$sha" "$(show "$path")"
        continue
      fi
      actual="$(g hash-object -- "$path")" || continue
      if [ "$actual" != "$sha" ]; then
        printf '  %s: working file %s hashes to %s; not restored\n' "$sha" "$(show "$path")" "$actual"
        continue
      fi
      g hash-object -w -- "$path" > /dev/null
      if g cat-file -e "$sha" 2>/dev/null; then
        printf '  %s: restored from %s\n' "$sha" "$(show "$path")"
        restored=1
        RESTORED_ANY=1
        break
      fi
    done < "$WORK/missing-index"
    if [ "$restored" = "0" ]; then
      printf '  %s: no working file hashes to this id; not restored\n' "$sha"
    fi
  done < "$WORK/candidates"
}

fix() {
  local icons p left rc
  find_icons
  icons="$(count_nul "$WORK/icons")"
  if [ "$icons" != "0" ]; then
    printf 'deleting %s Icon\\r file(s) under %s:\n' "$icons" "$(show "$GIT_DIR_PATH")"
    while IFS= read -r -d '' p; do
      # Belt and braces: only ever delete the exact name.
      [ "$(basename "$p")" = "$ICON_NAME" ] || continue
      rm -f -- "$p"
      printf '  %s\n' "$(show "${p#"$GIT_DIR_PATH"/}")"
    done < "$WORK/icons"
    find_icons
    left="$(count_nul "$WORK/icons")"
    [ "$left" = "0" ] || die "$left Icon\\r file(s) could not be deleted"
  else
    printf 'no Icon\\r files under %s\n' "$(show "$GIT_DIR_PATH")"
  fi

  rc=0
  g fsck --no-dangling > "$WORK/fsck" 2>&1 || rc=$?
  [ "$rc" = "0" ] || printf 'git fsck reported problems; checking for missing objects to restore:\n'
  # Missing index objects are checked directly as well as through fsck.
  RESTORED_ANY=0
  restore_missing_objects "$WORK/fsck"

  # Re-run fsck only when the first run failed or an object was written.
  if [ "$rc" != "0" ] || [ "$RESTORED_ANY" = "1" ]; then
    rc=0
    g fsck --no-dangling > "$WORK/fsck" 2>&1 || rc=$?
  fi
  if [ "$rc" = "0" ]; then
    printf 'ok: git fsck is clean\n'
    return 0
  fi
  printf 'git fsck still reports problems:\n'
  sed -n '1,40p' "$WORK/fsck" | sed 's/^/  /'
  printf 'These need a manual repair; do not run git gc --prune until they are understood.\n'
  return 2
}

icloud_warning
if [ "$FIX" = "1" ]; then
  fix
else
  report
fi
