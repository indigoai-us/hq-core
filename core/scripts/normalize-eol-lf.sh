#!/usr/bin/env bash
# normalize-eol-lf.sh — rewrite the HQ worktree so tracked text is LF on disk.
#
# Why: root `.gitattributes` uses `* text=auto eol=lf`. Fresh clones/checkouts
# get LF everywhere. An *existing* Windows worktree that already materialized
# CRLF (core.autocrlf / older text=auto) does NOT rewrite those bytes on pull
# of the attributes change — `git status` stays clean while on-disk content
# remains CRLF. Desktop Core Drift and bash hooks care about on-disk bytes.
#
# This script strips the CR from every tracked file git reports as CRLF or
# mixed on disk (`git ls-files --eol`), then refreshes the index. It does not
# go through `git checkout-index`, which skips files git already considers
# up to date and so leaves a clean-status CRLF worktree untouched.
#
# Safe on macOS/Linux (no-op when files are already LF). Refuses a dirty tree
# so it never clobbers uncommitted edits.
#
# Usage:
#   bash core/scripts/normalize-eol-lf.sh [hq_root]
#   HQ_ROOT=/path/to/hq bash core/scripts/normalize-eol-lf.sh
#
# Exit codes:
#   0  success (or nothing to do)
#   1  not an HQ git root / git missing
#   2  working tree or index dirty — commit/stash first
#   3  file rewrite failed

set -euo pipefail

hq_root="${1:-${HQ_ROOT:-}}"
if [ -z "$hq_root" ]; then
  hq_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "$hq_root" ]; then
  hq_root="$PWD"
fi

if [ ! -d "$hq_root/.git" ] && [ ! -f "$hq_root/.git" ]; then
  # Worktree .git can be a file; still need git -C to work.
  if ! git -C "$hq_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "normalize-eol-lf: not a git worktree: $hq_root" >&2
    exit 1
  fi
fi

if [ ! -f "$hq_root/core/core.yaml" ] && [ ! -f "$hq_root/core.yaml" ]; then
  echo "normalize-eol-lf: not an HQ root (missing core/core.yaml): $hq_root" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "normalize-eol-lf: git not found on PATH" >&2
  exit 1
fi

# Dirty check — both worktree and index must be clean.
if ! git -C "$hq_root" diff --quiet --ignore-submodules -- 2>/dev/null \
  || ! git -C "$hq_root" diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
  echo "normalize-eol-lf: working tree or index is dirty — commit or stash first." >&2
  echo "  Then re-run: bash core/scripts/normalize-eol-lf.sh \"$hq_root\"" >&2
  exit 2
fi

# Re-apply clean filters to the index (no-op when blobs already LF).
git -C "$hq_root" add --renormalize . >/dev/null 2>&1 || true

# If renormalize staged anything unexpected, refuse rather than leave a dirty index.
if ! git -C "$hq_root" diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
  echo "normalize-eol-lf: renormalize staged index changes — review with git status, then commit or reset." >&2
  exit 2
fi

# Rewrite the CRLF files directly. `git checkout-index -f -a` and
# `git checkout -- <path>` both consult the index's cached stat data and skip
# a file git already considers up to date, which is exactly the state a
# CRLF worktree is in once `text=auto` normalizes the comparison: status is
# clean, so nothing is rewritten and the CR bytes stay on disk (seen on
# macOS git 2.54 and Windows Git Bash alike). `git ls-files --eol` reports
# the on-disk ending per tracked text file, so strip the CR from those files
# ourselves and let git refresh its stat cache afterwards.
rewritten=0
while IFS= read -r -d '' entry; do
  case "$entry" in
    *$'\t'*) ;;
    *) continue ;;
  esac
  attrs="${entry%%$'\t'*}"
  file="${entry#*$'\t'}"
  case " $attrs " in
    *" w/crlf "*|*" w/mixed "*) ;;
    *) continue ;;
  esac
  [ -f "$hq_root/$file" ] && [ ! -L "$hq_root/$file" ] || continue
  if ! perl -pi -e 's/\r$//' "$hq_root/$file"; then
    echo "normalize-eol-lf: could not rewrite $file" >&2
    exit 3
  fi
  rewritten=$((rewritten + 1))
done < <(git -C "$hq_root" ls-files --eol -z)

git -C "$hq_root" update-index --refresh >/dev/null 2>&1 || true

if [ "$rewritten" -eq 0 ]; then
  echo "normalize-eol-lf: tracked worktree under $hq_root already matches eol=lf policy"
else
  echo "normalize-eol-lf: rewrote $rewritten tracked file(s) under $hq_root to match eol=lf policy"
fi
exit 0
