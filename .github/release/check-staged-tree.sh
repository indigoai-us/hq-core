#!/usr/bin/env bash
# check-staged-tree.sh: reject repository-only tests and tooling in a release.
#
# Usage: check-staged-tree.sh <staged tree> [<source tree>]
#
# release.yml stages the release tree with the filter rules in
# install-excludes.rsync and then runs this check on the result. The check does
# not read that file: it walks the staged tree and tests each path against its
# own copy of the rules, so a rule dropped from the filter file is caught.
#
# With <source tree>, also require every non-excluded core file. This protects
# runtime helpers and test-named worker documents against overly broad filters.
#
# Exit 0: valid release. Exit 1: invalid contents. Exit 2: invalid arguments.
set -euo pipefail

[ "$#" -ge 1 ] && [ -d "$1" ] || { echo "usage: check-staged-tree.sh <staged tree> [<source tree>]" >&2; exit 2; }
stage=$1
source_tree=${2:-}
if [ -n "$source_tree" ] && [ ! -d "$source_tree/core" ]; then
  echo "check-staged-tree: source tree has no core directory" >&2
  exit 2
fi

# Paths that match a rule below and still ship. Keep in step with the "+" lines
# of install-excludes.rsync.
is_kept() {
  case "$1" in
    core/workers/public/qa-tester/tests/*) return 0 ;;
    core/scripts/tests/deep-plan-hq-context-scanner.test.sh) return 0 ;;
    core/scripts/tests/skill-script-refs.test.sh) return 0 ;;
    core/scripts/tests/skill-core-script-references.test.sh) return 0 ;;
    core/scripts/tests/skill-body-positional-placeholders.test.sh) return 0 ;;
    core/scripts/tests/skill-company-bind-before-read.test.sh) return 0 ;;
    core/scripts/tests/agent-runtime-skill-metadata.test.sh) return 0 ;;
    core/scripts/tests/agent-runtime-permissions.test.sh) return 0 ;;
  esac
  return 1
}

# Keep in step with the "-" lines of install-excludes.rsync.
is_test_file() {
  local rel=$1 base=${1##*/}
  case "/$rel" in
    */tests/*|*/__tests__/*|*/__fixtures__/*|*/__snapshots__/*) return 0 ;;
  esac
  case "$rel" in
    core/scripts/ci/*|core/scripts/check-cli-hosted.sh|core/scripts/check-deleted-script-refs.sh) return 0 ;;
    core/scripts/compute-checksums.sh) return 0 ;;
    core/scripts/check-preflight-fixtures.sh) return 0 ;;
    core/scripts/check-pricing-drift.sh) return 0 ;;
    core/scripts/generate-adapter-capabilities.sh) return 0 ;;
    core/scripts/generate-openai-yaml.sh) return 0 ;;
    core/scripts/lint-hook-heredoc-nesting.js) return 0 ;;
    core/scripts/lint-install-deps.sh) return 0 ;;
    core/scripts/lint-shell-errors.sh) return 0 ;;

    core/scripts/parse-release-tag.sh|core/scripts/promote-release-pr-guard.sh) return 0 ;;
    core/scripts/publish-hq-anywhere-runtime-assets.sh) return 0 ;;
    core/scripts/release-pr-auto-merge.sh|core/scripts/release-pr-check-gate.sh) return 0 ;;
    core/scripts/build-claude-plugin.sh|core/scripts/build-codex-pack.sh) return 0 ;;
    core/scripts/build-claude-marketplace.sh) return 0 ;;
    test/*|core/scripts/hook-corpus/*) return 0 ;;
    core/workers/public/content-shared/test/*) return 0 ;;
    .claude/skills/daily-brief/scripts/fixtures/*) return 0 ;;
    core/scripts/test-codex-hook-adapter.sh|core/scripts/anywhere-parity-test.sh) return 0 ;;
    core/scripts/anywhere-vm-test.sh|.claude/skills/outpost-host/test-guard.sh) return 0 ;;
  esac
  case "$base" in
    *.test.sh|*.test.bash|*.test.mjs|*.test.cjs|*.test.js|*.test.ts|*.test.tsx|*.test.py|*.test.ps1) return 0 ;;
    *.spec.sh|*.spec.bash|*.spec.mjs|*.spec.cjs|*.spec.js|*.spec.ts|*.spec.tsx|*.spec.py|*.spec.ps1) return 0 ;;
    test_*.py) return 0 ;;
  esac
  return 1
}

found=0
total=0
while IFS= read -r -d '' path; do
  rel=${path#"$stage"/}
  total=$((total + 1))
  if is_kept "$rel"; then continue; fi
  if is_test_file "$rel"; then
    found=$((found + 1))
    echo "check-staged-tree: test or tooling file in the release tree: $rel"
  fi
done < <(find "$stage" \( -type f -o -type l \) -print0)

# Empty test folders must not ship either.
while IFS= read -r -d '' path; do
  rel=${path#"$stage"/}
  # core/scripts/tests holds the kept files, so the folder itself ships.
  [ "$rel" = "core/scripts/tests" ] && continue
  if ! is_kept "$rel/x" && is_test_file "$rel/x"; then
    found=$((found + 1))
    echo "check-staged-tree: test or tooling folder in the release tree: $rel"
  fi
done < <(find "$stage" -mindepth 1 -type d -print0)

missing=0
if [ -n "$source_tree" ]; then
  while IFS= read -r -d '' path; do
    rel=${path#"$source_tree"/}
    if ! is_kept "$rel" && is_test_file "$rel"; then continue; fi
    if [ ! -e "$stage/$rel" ] && [ ! -L "$stage/$rel" ]; then
      missing=$((missing + 1))
      echo "check-staged-tree: shipped file missing from the release tree: $rel"
    fi
  done < <(find "$source_tree/core" \( -type f -o -type l \) -print0)
fi

echo "check-staged-tree: $total files staged, $found test/tooling files or folders, $missing shipped files missing"
[ "$found" -eq 0 ] && [ "$missing" -eq 0 ]
