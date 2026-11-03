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
# The .codex entries are the legacy Codex hook layer (hooks.json plus per-hook
# .sh copies and hook-gate.sh) that predates hq-codex-hook-adapter.sh. Codex
# now runs the adapter from .codex/config.toml, which dispatches .claude/hooks.
# The legacy files were never in git; the sums are of the copies found on
# installs that still carry them. Shipped .codex files (the adapter,
# deny-core-edits.sh, the .cjs guards, hq-codex-hook.cmd) are never listed.
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
.codex/hooks.json b190e294d7d3e8a98d32c681bfc2adfbd4b1c0c3e2326024d36e4ad3c4fd706f
.codex/hooks/auto-capture-registry.sh a2d039fc6f2de71824ee0e370dc4dcc30fb9ed464d368062701a0a2726d93f82
.codex/hooks/auto-checkpoint-trigger.sh 4cba00be7196f8913895d53feb9e273547f41fd53f4b98a906d8eeeb31fa3b45
.codex/hooks/auto-continue-session.sh 7e1ae79c43b14aa6089ae0020c64c3d6f59f13062bb91d5a04a04d58c8a07d96
.codex/hooks/auto-handoff-trigger.sh 38a6ac7d884d6b04639bfcdbc66eb57cf0b7b6e7b561ce395a431bd276993173
.codex/hooks/block-env-dump.sh 37255e4c41a4f8e24688a1f4fef1cefd7e17bb0c330ff6c82bda0577ca522628
.codex/hooks/block-hq-glob.sh c73f8ca1c1ffc4bec2ad7314c68f4bdf80b07c2aceac0110d5b6c97fa51cba5e
.codex/hooks/block-hq-grep.sh d621c68d3536f43b308dfb7a29e94a6454b5306ddf41243a7d8667938d8cc658
.codex/hooks/block-inline-story-impl.sh 8902f90d3da361693c2d1bf51f182b8fa91b37d38e8700ee240d6091fa0b9807
.codex/hooks/block-op-leak.sh ff00c0c3ab2c3b11c4e63878d2666254265b54fb8f4515e9b7f425cc95c897aa
.codex/hooks/block-secret-cache-read.sh 243190a5b198bf3b0106f050516e9f834604186e46ce5c3cd57f60b376653854
.codex/hooks/check-update.sh fe629e4c8bcde33aea33fe1de33bb85fcc00de20733ef22d1994f94e629c66ac
.codex/hooks/context-meter.sh 645bb93abcfa91f38a86616f0e88b42acab8196801d38c3fd65b52d4b4de6d1a
.codex/hooks/detect-secrets.sh 92b9532538ea1f9e50cbe09c5444d776776c1cb08ef2c36fa9be95762e79915c
.codex/hooks/hook-gate.sh 95380f7d49dd6ed0521493bfbf475ec2d4e1d586b827f475cb071f37b35b8816
.codex/hooks/observe-patterns.sh 35771557ee83fbab91c24e24e7c622eee5c28f265529e90a0954cabd32a7e555
.codex/hooks/package-scope-gate.sh 72554931caf8e08ccabc009b186a1437b50d04b73ed89c5e3c8465883bf97f54
.codex/hooks/protect-core.sh aa36aa7d68693e8095f06ca702cab15444b96505d049706c81e0ca21888df16f
.codex/hooks/scan-output-secrets.sh a5670b31b51dc5a080d74c0187b177eeb25ae9e38794ac434f98dac51781570a
.codex/hooks/screenshot-resize-trigger.sh 9886bf16bb90951ce91c33d8f7b1026732ef3f32216ed7a875d8119602a784fe
.codex/hooks/sweetheart-encouragement.sh f7d3b449191e25b6f662a0e820fca6c001911b4718c5baba1ee3ceaa2cd41b5c
.codex/hooks/warn-cross-company-settings.sh acd7170a751219dc0cbe0e69e6ceb0398e1aecfb21306fd27c55675b69ecd00b
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
    echo "remove-retired-core-hooks: kept $rel (outside ${rel%/*}: its folder resolves to ${parent_phys:-an unreadable path})" >&2
    continue
  fi
  sum="$(sha256_of "$file")"
  [ -n "$sum" ] || continue
  if ! printf '%s\n' "$RETIRED" | grep -qxF "$rel $sum"; then
    echo "remove-retired-core-hooks: kept $rel (local edits; HQ no longer runs it, delete it by hand)" >&2
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
