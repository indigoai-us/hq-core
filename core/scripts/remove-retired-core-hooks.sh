#!/usr/bin/env bash
# hq-core: public
# remove-retired-core-hooks.sh — delete core hook files that a release retired
# but `hq rescue` left on disk.
#
# Usage: remove-retired-core-hooks.sh [hq-root] [--check]
#
# `hq rescue` keeps any file the new release no longer ships, so a retired
# core/hooks/<event>/*.sh leaf keeps running from master-hook.sh after the
# update that removed it. The retired Stop leaf 70-work-mesh-done.sh made a
# synchronous network report on every turn end (median ~14 s on affected
# installs) after US-010 replaced it with the enqueue-only
# 70-work-mesh-turn-end.sh.
#
# A file is removed only when its sha256 matches a released copy listed below.
# Carriage returns are stripped before hashing, so a CRLF checkout of a
# released copy still matches. A file with any other content is a local edit:
# it is reported and kept.
#
# A file is removed only when its folder is the physical
# HQ_ROOT/core/hooks[/<event>]. If core, core/hooks or core/hooks/<event> is a
# symlink that resolves somewhere else (personal/, a company folder), the file
# is reported as "kept (outside core/hooks)" and left alone.
#
# The retired Stop leaves listed here must match the skip list in
# .claude/hooks/master-hook.sh; remove-retired-core-hooks.test.sh checks that.
#
# --check  remove nothing; print each retired file still present and exit 1
#          when at least one is found.
#
# Exit status in default mode: 0, or 1 when a removal failed.
set -uo pipefail
# cd prints the folder when CDPATH matches, which would corrupt the
# physical-path comparison below.
unset CDPATH

HQ_ROOT=""
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    *) HQ_ROOT="$arg" ;;
  esac
done
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
[ -d "$HQ_ROOT/core" ] || exit 0
ROOT_PHYS="$(cd -P "$HQ_ROOT" 2>/dev/null && pwd -P)" || exit 0

# path <space> sha256 of a released copy. One line per released version.
RETIRED='
core/hooks/Stop/70-work-mesh-done.sh b65b3b3cbcb1a9422cdd7f9cbc650b93e41d66d9f8094c8f4f133191af3f4c0d
core/hooks/work-mesh-done.sh 367dab8a562ffa4e6c6a8eed7d7caa6abc57dfc225d30b99651a93198bd61486
core/hooks/work-mesh-done.sh dbc0ef6e0ad6e4d300710c88b5f096a6be3ff69ee2e8f4d955b2d3b21c589974
'

# sha256 of the file with carriage returns removed.
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    tr -d '\r' < "$1" 2>/dev/null | shasum -a 256 | cut -c1-64
  elif command -v sha256sum >/dev/null 2>&1; then
    tr -d '\r' < "$1" 2>/dev/null | sha256sum | cut -c1-64
  fi
}

found=0
failed=0
seen=" "
while read -r rel _; do
  [ -n "$rel" ] || continue
  case "$seen" in *" $rel "*) continue ;; esac
  seen="$seen$rel "
  file="$HQ_ROOT/$rel"
  [ -f "$file" ] && [ ! -L "$file" ] || continue
  parent_phys="$(cd -P "${file%/*}" 2>/dev/null && pwd -P)"
  if [ "$parent_phys" != "$ROOT_PHYS/${rel%/*}" ]; then
    echo "remove-retired-core-hooks: kept $rel (outside core/hooks: its folder resolves to ${parent_phys:-an unreadable path})" >&2
    continue
  fi
  sum="$(sha256_of "$file")"
  [ -n "$sum" ] || continue
  if ! printf '%s\n' "$RETIRED" | grep -qxF "$rel $sum"; then
    echo "remove-retired-core-hooks: kept $rel (local edits; master-hook no longer runs it, delete it by hand)" >&2
    continue
  fi
  found=1
  if [ "$CHECK" -eq 1 ]; then
    echo "remove-retired-core-hooks: retired file present: $rel"
  elif rm -f "$file" && [ ! -e "$file" ]; then
    echo "remove-retired-core-hooks: removed $rel"
  else
    failed=1
    echo "remove-retired-core-hooks: could not remove $rel; delete it by hand" >&2
  fi
done <<EOF
$RETIRED
EOF

[ "$CHECK" -eq 1 ] && [ "$found" -eq 1 ] && exit 1
[ "$failed" -eq 1 ] && exit 1
exit 0
