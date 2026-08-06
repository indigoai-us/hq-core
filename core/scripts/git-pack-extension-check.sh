#!/usr/bin/env bash
# hq-core: public
# git-pack-extension-check.sh — find pack files that have lost their extension.
#
# A git packfile set is three files sharing one basename:
#
#   pack-<sha>.pack   the objects           (magic "PACK")
#   pack-<sha>.idx    the index into them   (magic "\377tOc")
#   pack-<sha>.rev    reverse index         (magic "RIDX")
#
# Git pairs them BY EXTENSION. Strip the extension off any one of them and git
# stops seeing the set entirely: the objects are still on disk, byte for byte,
# but they become unreachable. The repo then fails in a way that reads like
# catastrophic history loss rather than a filename problem:
#
#   fatal: unable to read tree (<sha>)
#   error: bad tree object HEAD
#   error: refs/heads/<branch>: invalid sha1 pointer <sha>
#
# `git fsck` reports the objects as missing and `git gc` cannot help, because
# nothing is actually corrupt — the bytes are intact and the repair is a
# rename. That mismatch between how it presents and what it is makes this
# failure expensive to diagnose from the error text alone, which is why this
# check exists as a deterministic probe.
#
# Git never writes an extensionless `pack-*` file, so finding one is
# unambiguous. Observed in the wild on a macOS HQ root where a folder-level
# sync/backup agent had been walking the tree; the mechanism that drops the
# extension is not established.
#
# Usage:
#   git-pack-extension-check.sh [--root <path>] [--fix] [--quiet]
#
#   --root <path>   Repository to check (default: current directory).
#   --fix           Rename each orphan back to the extension its magic bytes
#                   prove it should carry. Without this the script only
#                   reports.
#   --quiet         Suppress the healthy-case line; findings still print.
#
# Exit codes:
#   0  healthy, or every orphan was repaired under --fix
#   1  usage error, or the root is not a git repository
#   2  orphans found and left in place (report-only, or unrepairable)
#
# The repair is a rename and nothing else. It never deletes, never rewrites
# file contents, never touches refs or the index, and refuses to overwrite an
# existing target. A file whose magic bytes are not a known pack signature is
# reported and left alone — this script will not guess.

set -uo pipefail

ROOT="."
FIX=0
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || { echo "git-pack-extension-check: --root needs a path" >&2; exit 1; }
      ROOT="$2"; shift 2 ;;
    --fix)   FIX=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help)
      sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "git-pack-extension-check: unknown argument '$1'" >&2
      exit 1 ;;
  esac
done

if [[ ! -d "$ROOT" ]]; then
  echo "git-pack-extension-check: not a directory: $ROOT" >&2
  exit 1
fi

# Packs live in the COMMON git dir, not the per-worktree one — a linked
# worktree shares the main object store, so checking either resolves to the
# same place. `--path-format=absolute` needs git 2.31+; the fallback keeps
# this working on older hosts by resolving the (possibly relative) path
# against the repo root itself.
GIT_COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [[ -z "$GIT_COMMON" ]]; then
  GIT_COMMON="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -z "$GIT_COMMON" ]]; then
    echo "git-pack-extension-check: not a git repository: $ROOT" >&2
    exit 1
  fi
  if [[ "$GIT_COMMON" != /* ]]; then
    GIT_COMMON="$(cd "$ROOT" && cd "$GIT_COMMON" 2>/dev/null && pwd || true)"
  fi
fi

PACK_DIR="$GIT_COMMON/objects/pack"
if [[ ! -d "$PACK_DIR" ]]; then
  [[ "$QUIET" == "1" ]] || echo "git-pack-extension-check: no pack directory, nothing to check"
  exit 0
fi

# The magic bytes are read with `od` rather than compared as shell strings:
# a packfile is binary and its first bytes can include NUL, which a shell
# variable cannot hold.
magic_of() {
  od -A n -t x1 -N 4 "$1" 2>/dev/null | tr -d ' \n'
}

FOUND=0
REPAIRED=0
UNREPAIRED=0

# NUL-delimited: a mangled filename is exactly the case where a newline in a
# name would split the list and corrupt the scan.
while IFS= read -r -d '' orphan; do
  base="$(basename "$orphan")"
  hex="$(magic_of "$orphan")"
  case "$hex" in
    5041434b) ext="pack" ;;   # "PACK"
    ff744f63) ext="idx"  ;;   # "\377tOc"
    52494458) ext="rev"  ;;   # "RIDX"
    *)        ext="" ;;
  esac

  FOUND=$((FOUND + 1))

  if [[ -z "$ext" ]]; then
    echo "git-pack-extension-check: FOUND $base — extensionless, but its magic bytes (${hex:-empty}) are not a pack/idx/rev signature; leaving it alone" >&2
    UNREPAIRED=$((UNREPAIRED + 1))
    continue
  fi

  target="$orphan.$ext"
  if [[ -e "$target" ]]; then
    echo "git-pack-extension-check: FOUND $base — should be $base.$ext, but that file already exists; resolve by hand" >&2
    UNREPAIRED=$((UNREPAIRED + 1))
    continue
  fi

  if [[ "$FIX" != "1" ]]; then
    echo "git-pack-extension-check: FOUND $base — lost its .$ext extension; git cannot see this pack set. Re-run with --fix to rename it." >&2
    UNREPAIRED=$((UNREPAIRED + 1))
    continue
  fi

  if mv -n "$orphan" "$target" 2>/dev/null && [[ -e "$target" && ! -e "$orphan" ]]; then
    echo "git-pack-extension-check: REPAIRED $base -> $base.$ext"
    REPAIRED=$((REPAIRED + 1))
  else
    echo "git-pack-extension-check: FAILED to rename $base -> $base.$ext" >&2
    UNREPAIRED=$((UNREPAIRED + 1))
  fi
done < <(find "$PACK_DIR" -maxdepth 1 -type f -name 'pack-*' ! -name '*.*' -print0 2>/dev/null)

if [[ "$FOUND" -eq 0 ]]; then
  [[ "$QUIET" == "1" ]] || echo "git-pack-extension-check: ok — no extensionless pack files in $PACK_DIR"
  exit 0
fi

if [[ "$UNREPAIRED" -gt 0 ]]; then
  echo "git-pack-extension-check: ${FOUND} orphan(s), ${REPAIRED} repaired, ${UNREPAIRED} still broken" >&2
  exit 2
fi

echo "git-pack-extension-check: ${REPAIRED} pack file(s) repaired — re-run 'git fsck' to confirm"
exit 0
