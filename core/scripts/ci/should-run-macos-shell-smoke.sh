#!/usr/bin/env bash
# Decide whether a push or PR changed a path exercised by shell-smoke-macos.
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: should-run-macos-shell-smoke.sh <base-sha> <head-sha> <repo-root>" >&2
  exit 2
fi

base_sha="$1"
head_sha="$2"
repo_root="$3"

if [[ -z "$head_sha" ]] || ! git -C "$repo_root" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
  echo "head commit is unavailable for macOS shell smoke path detection" >&2
  exit 2
fi

# Missing base history happens for initial or force-push events. Fail open so
# the platform tests run instead of silently suppressing coverage.
if [[ -z "$base_sha" ]] || ! git -C "$repo_root" cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
  echo "run=true"
  exit 0
fi

changed_paths="$(git -C "$repo_root" diff --name-only "$base_sha" "$head_sha" -- \
  .github/workflows/pr-checks.yml \
  ':(glob)**/*.sh' \
  ':(glob)**/*.bash' \
  ':(glob)**/*.bats' \
  ':(glob).claude/settings.json' \
  ':(glob).claude/hooks/**' \
  ':(glob).grok/hooks/**' \
  ':(glob)core/core.yaml' \
  ':(glob).claude/skills/deploy/SKILL.md' \
  ':(glob)core/scripts/lib/**')"

if [[ -n "$changed_paths" ]]; then
  echo "run=true"
else
  echo "run=false"
fi
