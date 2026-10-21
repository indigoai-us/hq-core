#!/usr/bin/env bash
# hq-core: public
# hq-root-git-reinit.sh — Re-create or repair the HQ root's local git history
# without recording nested repos as gitlinks.
#
# The HQ root is a local-only git repo used for autosave. Company knowledge
# folders and project folders are often their own git repos. A plain
# `git init && git add -A` at the HQ root records each of them as an embedded
# gitlink (mode 160000) with no .gitmodules: the tree stays dirty, autosave
# refuses those paths, and /handoff and session archiving are blocked.
# (Shepherd 2638)
#
# Usage:
#   bash core/scripts/hq-root-git-reinit.sh [--root DIR] --check
#       Report gitlinks in the HQ root index. Exit 0 when clean, 2 when found.
#   bash core/scripts/hq-root-git-reinit.sh [--root DIR] --reinit [--no-commit]
#       The HQ root has no .git: init, exclude every nested repo, add, commit.
#   bash core/scripts/hq-root-git-reinit.sh [--root DIR] --repair [--no-commit]
#       The HQ root already records gitlinks: drop them from the index only
#       (working files are untouched), exclude those paths, commit.
#       When the HQ root has no commit yet (an interrupted --reinit, or a
#       naive `git init && git add -A`), --repair instead finishes the
#       re-init: it rebuilds the index with the same exclusions, then adds
#       and commits the whole tree. If --reinit stopped at the commit (for
#       example no usable git identity), fix that and run --repair.
#
# --reinit and the no-commit --repair run only on an HQ root (core/core.yaml)
# that is not inside another git work tree. Nested repos are listed in
# .git/info/exclude, never in the shipped .gitignore, so the exclusion stays
# machine-local. Exit codes: 0 ok, 1 usage or git error (including a failed
# commit), 2 gitlinks found (--check only).

set -euo pipefail

ROOT=""
MODE=""
COMMIT=1
EXCLUDE_MARKER="# hq-root-git-reinit: nested repos (never record as gitlinks)"

usage() {
  sed -n '4,33p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

die() {
  printf 'hq-root-git-reinit: %s\n' "$1" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || die "--root needs a directory"; ROOT="$2"; shift 2 ;;
    --check) MODE="check"; shift ;;
    --reinit) MODE="reinit"; shift ;;
    --repair) MODE="repair"; shift ;;
    --no-commit) COMMIT=0; shift ;;
    -h|--help) usage 0 ;;
    *) printf 'hq-root-git-reinit: unknown argument: %s\n' "$1" >&2; usage 1 ;;
  esac
done

[ -n "$MODE" ] || usage 1
if [ -z "$ROOT" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
[ -d "$ROOT" ] || die "not a directory: $ROOT"
# Physical path: git reports the real top level (macOS /tmp is a symlink).
ROOT="$(cd "$ROOT" && pwd -P)"

# Every git call below is scoped to this root and allowed past the HQ-root git
# guard, which exists to stop accidental mutations, not this repair.
export HQ_ALLOW_HQ_ROOT_GIT=1
g() { git -C "$ROOT" "$@"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

is_root_repo() {
  [ -e "$ROOT/.git" ] || return 1
  local top
  top="$(g rev-parse --show-toplevel 2>/dev/null)" || return 1
  # Normalize through the shell: Git for Windows prints C:/... while
  # Git Bash's pwd prints /c/....
  [ "$(cd "$top" 2>/dev/null && pwd -P)" = "$ROOT" ]
}

# --reinit and the no-commit --repair add and commit the whole tree, so they
# run only on an HQ root: core/core.yaml present (v15+; older HQs keep
# core.yaml at the root) and no enclosing git work tree. The second check
# refuses <HQ>/core, which has a core.yaml of its own.
require_hq_root() {
  if [ ! -f "$ROOT/core/core.yaml" ] && [ ! -f "$ROOT/core.yaml" ]; then
    die "$ROOT does not look like an HQ root (no core/core.yaml); run this on the HQ root only"
  fi
  local parent
  parent="$(dirname "$ROOT")"
  if [ "$parent" != "$ROOT" ] && git -C "$parent" rev-parse --show-toplevel >/dev/null 2>&1; then
    die "$ROOT is inside another git work tree; run this on the HQ root only"
  fi
}

has_head() { g rev-parse -q --verify HEAD >/dev/null; }

# Secret folders stay out of local history even when an older HQ .gitignore
# predates these lines. Written once under a marker in .git/info/exclude.
SECRET_MARKER="# hq-root-git-reinit: secret folders (never commit)"
exclude_secret_folders() {
  local exclude_file
  exclude_file="$(g rev-parse --git-path info/exclude)"
  case "$exclude_file" in /*) ;; *) exclude_file="$ROOT/$exclude_file" ;; esac
  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"
  grep -qxF "$SECRET_MARKER" "$exclude_file" && return 0
  printf '\n%s\n%s\n%s\n' "$SECRET_MARKER" "/companies/*/secrets/" ".secrets/" >>"$exclude_file"
}

# Write index paths recorded as gitlinks to $1, NUL-separated. The git listing
# goes to a file first so a git failure (corrupt index, stale lock) stops the
# script under set -e instead of reading as an empty list.
staged_gitlinks() {
  g ls-files --stage -z >"$WORK/stage"
  : >"$1"
  local entry
  while IFS= read -r -d '' entry; do
    case "$entry" in
      "160000 "*) printf '%s\0' "${entry#*$'\t'}" >>"$1" ;;
    esac
  done <"$WORK/stage"
}

# Write untracked nested repos to $1, NUL-separated, without a trailing slash.
# Git reports an embedded repo as a single `path/` entry and never descends
# into it; ignored trees such as /repos/ are skipped by --exclude-standard.
untracked_nested_repos() {
  g ls-files --others --exclude-standard -z >"$WORK/others"
  : >"$1"
  local path
  while IFS= read -r -d '' path; do
    case "$path" in
      */) printf '%s\0' "${path%/}" >>"$1" ;;
    esac
  done <"$WORK/others"
}

has_newline() {
  case "$1" in *$'\n'*|*$'\r'*) return 0 ;; esac
  return 1
}

# Escape gitignore glob characters so the exclude line matches only this path.
exclude_pattern() {
  local p="$1"
  p="${p//\\/\\\\}"
  p="${p//\[/\\[}"
  p="${p//\]/\\]}"
  p="${p//\*/\\*}"
  p="${p//\?/\\?}"
  printf '/%s/' "$p"
}

exclude_paths() {
  local exclude_file
  exclude_file="$(g rev-parse --git-path info/exclude)"
  case "$exclude_file" in /*) ;; *) exclude_file="$ROOT/$exclude_file" ;; esac
  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"
  grep -qxF "$EXCLUDE_MARKER" "$exclude_file" || printf '\n%s\n' "$EXCLUDE_MARKER" >>"$exclude_file"
  local path line
  for path in "$@"; do
    line="$(exclude_pattern "$path")"
    grep -qxF -- "$line" "$exclude_file" || printf '%s\n' "$line" >>"$exclude_file"
  done
}

# Index-only removal: the nested repos and their files stay on disk.
# --literal-pathspecs keeps bracketed names from being read as globs.
unstage_paths() {
  g --literal-pathspecs rm -q --cached -f -r -- "$@"
}

commit_index() {
  local message="$1"
  g diff --cached --quiet && return 0
  # No git identity on this machine: fill the missing parts with a placeholder
  # scoped to this one commit, the same fallback create-hq uses. A configured
  # user.name is kept.
  local -a ident=()
  [ -n "$(g config user.email 2>/dev/null || true)" ] || ident+=(-c user.email="hq@localhost")
  [ -n "$(g config user.name 2>/dev/null || true)" ] || ident+=(-c user.name="HQ")
  # Report a failed commit as exit 1 (documented), not git's own 128.
  g ${ident[@]+"${ident[@]}"} commit -q -m "$message" ||
    die "git commit failed in $ROOT; fix the cause (often git identity) and run --repair to finish"
}

# Exclude nested repos, add everything, and drop anything git still staged
# as a gitlink. Sets NESTED to every excluded path, or LINEBREAK=1 (and stops
# before adding) when a nested repo name has a line break. Used by --reinit
# and by --repair on a repo that has no commit yet (an interrupted re-init).
# Always call it as a plain statement: under `cmd || ...` bash turns off
# set -e inside the function and a failed git add would pass silently.
build_index() {
  LINEBREAK=0
  exclude_secret_folders
  untracked_nested_repos "$WORK/nested"
  read_list "$WORK/nested"
  NESTED=()
  [ "${#LIST[@]}" -eq 0 ] || NESTED=("${LIST[@]}")
  local path
  for path in ${NESTED[@]+"${NESTED[@]}"}; do
    if has_newline "$path"; then
      LINEBREAK=1
      return 0
    fi
  done
  [ "${#NESTED[@]}" -eq 0 ] || exclude_paths "${NESTED[@]}"
  g add -A
  staged_gitlinks "$WORK/leftover"
  read_list "$WORK/leftover"
  if [ "${#LIST[@]}" -gt 0 ]; then
    unstage_paths "${LIST[@]}"
    for path in "${LIST[@]}"; do
      has_newline "$path" || exclude_paths "$path"
    done
    NESTED+=("${LIST[@]}")
  fi
}

read_list() { # read_list <file> -> LIST array
  LIST=()
  local path
  while IFS= read -r -d '' path; do LIST+=("$path"); done <"$1"
}

case "$MODE" in
  check)
    is_root_repo || die "$ROOT is not the top of a git repo"
    staged_gitlinks "$WORK/gitlinks"
    read_list "$WORK/gitlinks"
    if [ "${#LIST[@]}" -eq 0 ]; then
      echo "hq-root-git-reinit: no gitlinks in the HQ root index"
      exit 0
    fi
    echo "hq-root-git-reinit: ${#LIST[@]} gitlink(s) recorded in the HQ root index:"
    printf '  %s\n' "${LIST[@]}"
    echo "Run with --repair to drop them from the index and exclude them."
    exit 2
    ;;

  reinit)
    [ ! -e "$ROOT/.git" ] || die "$ROOT/.git already exists; use --check or --repair"
    # Only the HQ root. A new repo in a subfolder would itself become a
    # gitlink in the HQ root.
    require_hq_root
    g init -q -b main >/dev/null 2>&1 || g init -q
    build_index
    if [ "$LINEBREAK" -eq 1 ]; then
      # The exclude file cannot express a line-break name. Remove the repo this
      # run just created so the user can rename the folder and run again.
      rm -rf "$ROOT/.git"
      die "a nested repo path contains a line break; rename it and run again"
    fi
    [ "$COMMIT" -eq 0 ] || commit_index "Re-initialize HQ root history"
    echo "hq-root-git-reinit: initialized $ROOT; excluded ${#NESTED[@]} nested repo(s)"
    [ "${#NESTED[@]}" -eq 0 ] || printf '  %s\n' "${NESTED[@]}"
    ;;

  repair)
    is_root_repo || die "$ROOT is not the top of a git repo"
    # The no-commit branch adds and commits the whole tree; never do that in
    # a nested project repo. Checked before anything is written.
    has_head || require_hq_root
    # Keep a copy of the index; every change below is index-only.
    index_file="$(g rev-parse --git-path index)"
    case "$index_file" in /*) ;; *) index_file="$ROOT/$index_file" ;; esac
    # Keep the first backup: a later run must not overwrite the original.
    if [ -f "$index_file" ] && [ ! -e "$index_file.hq-root-git-reinit.bak" ]; then
      cp "$index_file" "$index_file.hq-root-git-reinit.bak"
    fi
    if ! has_head; then
      # No commit yet: an interrupted or naive re-init. Finish it from an
      # empty index so files a naive `git add -A` staged (gitlinks, secret
      # folders) go through the same exclusions as --reinit. With no HEAD
      # nothing committed is lost; working files are not touched.
      g read-tree --empty
      build_index
      [ "$LINEBREAK" -eq 0 ] || die "a nested repo path contains a line break; rename it and run again"
      [ "$COMMIT" -eq 0 ] || commit_index "Re-initialize HQ root history"
      echo "hq-root-git-reinit: finished an uncommitted re-init of $ROOT; excluded ${#NESTED[@]} nested repo(s)"
      [ "${#NESTED[@]}" -eq 0 ] || printf '  %s\n' "${NESTED[@]}"
      exit 0
    fi
    staged_gitlinks "$WORK/gitlinks"
    read_list "$WORK/gitlinks"
    if [ "${#LIST[@]}" -eq 0 ]; then
      echo "hq-root-git-reinit: no gitlinks to repair"
      exit 0
    fi
    found=("${LIST[@]}")
    # The repair commit must hold only the gitlink removals. Staged gitlinks
    # are what this repairs, so they do not count.
    if [ "$COMMIT" -eq 1 ]; then
      g diff --cached --name-only -z >"$WORK/staged"
      other=0
      while IFS= read -r -d '' path; do
        is_found=0
        for gl in "${found[@]}"; do [ "$gl" != "$path" ] || { is_found=1; break; }; done
        [ "$is_found" -eq 1 ] || { other=1; break; }
      done <"$WORK/staged"
      [ "$other" -eq 0 ] || die "other changes are already staged in $ROOT; commit or unstage them first, or pass --no-commit"
    fi
    unstage_paths "${found[@]}"
    # Exclude only folders that are still repos; a folder that lost its .git
    # holds plain files that belong in autosave history. The exclude file
    # cannot express a name with a line break, so that folder is reported.
    still_repos=()
    for path in "${found[@]}"; do
      [ -e "$ROOT/$path/.git" ] || continue
      if has_newline "$path"; then
        printf 'hq-root-git-reinit: not excluded (line break in name; rename the folder): %q\n' "$path" >&2
        continue
      fi
      still_repos+=("$path")
    done
    [ "${#still_repos[@]}" -eq 0 ] || exclude_paths "${still_repos[@]}"
    [ "$COMMIT" -eq 0 ] || commit_index "Remove nested repo gitlinks from HQ root history"
    echo "hq-root-git-reinit: removed ${#found[@]} gitlink(s) from the index; excluded ${#still_repos[@]}:"
    printf '  %s\n' "${found[@]}"
    ;;
esac
