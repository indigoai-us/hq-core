#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stage="$tmp/stage"
mkdir -p "$stage"
rsync -a --exclude=.git --exclude=.github --exclude=.leak-scan \
  --exclude-from="$root/.github/release/install-excludes.rsync" "$root/" "$stage/"
for rel in core/scripts/ci core/scripts/parse-release-tag.sh \
  core/scripts/promote-release-pr-guard.sh core/scripts/release-pr-auto-merge.sh \
  core/scripts/release-pr-check-gate.sh core/scripts/publish-hq-anywhere-runtime-assets.sh \
  core/scripts/build-claude-plugin.sh core/scripts/build-codex-pack.sh \
  core/scripts/build-claude-marketplace.sh core/scripts/check-cli-hosted.sh \
  core/scripts/check-deleted-script-refs.sh core/scripts/check-preflight-fixtures.sh \
  core/scripts/check-pricing-drift.sh core/scripts/generate-adapter-capabilities.sh \
  core/scripts/generate-openai-yaml.sh core/scripts/lint-hook-heredoc-nesting.js \
  core/scripts/lint-install-deps.sh core/scripts/lint-shell-errors.sh \
  core/scripts/compute-checksums.sh; do
  if [ -e "$stage/$rel" ]; then
    echo "unexpected installed tooling: $rel" >&2
    exit 1
  fi
done
# Every exact tooling exclusion must be independently rejected by the checker.
for name in check-cli-hosted.sh check-deleted-script-refs.sh check-preflight-fixtures.sh \
  check-pricing-drift.sh generate-adapter-capabilities.sh generate-openai-yaml.sh \
  lint-hook-heredoc-nesting.js lint-install-deps.sh lint-shell-errors.sh compute-checksums.sh \
  parse-release-tag.sh promote-release-pr-guard.sh publish-hq-anywhere-runtime-assets.sh \
  release-pr-auto-merge.sh release-pr-check-gate.sh build-claude-plugin.sh \
  build-codex-pack.sh build-claude-marketplace.sh; do
  printf '#!/bin/sh\n' > "$stage/core/scripts/$name"
  if bash "$root/.github/release/check-staged-tree.sh" "$stage" "$root" > "$tmp/leak.log"; then
    echo "checker accepted leaked tooling: $name" >&2
    exit 1
  fi
  rm "$stage/core/scripts/$name"
done
bash "$root/.github/release/check-staged-tree.sh" "$stage" "$root"
# The independent checker must reject leaked CI files even if a filter regresses.
mkdir -p "$stage/core/scripts/ci"
printf '#!/bin/sh\n' > "$stage/core/scripts/ci/leaked.sh"
if bash "$root/.github/release/check-staged-tree.sh" "$stage" "$root" > "$tmp/leak.log"; then
  echo 'checker accepted leaked CI tooling' >&2
  exit 1
fi
rm -rf "$stage/core/scripts/ci"
# Missing runtime dependencies must also fail the release check.
rm "$stage/core/scripts/check-skill-edit.sh"
if bash "$root/.github/release/check-staged-tree.sh" "$stage" "$root" > "$tmp/missing.log"; then
  echo 'checker accepted missing runtime helper' >&2
  exit 1
fi
echo 'staged-tree tooling regression: PASS'
