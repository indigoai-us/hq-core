#!/usr/bin/env bash
# Decide whether a PR changes inputs measured by resumework-timing-linux.
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: should-run-resumework-timing.sh <base-sha> <head-sha> <repo-root>" >&2
  exit 2
fi

base_sha="$1"
head_sha="$2"
repo_root="$3"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shell, hook, settings, and workflow changes are already selected by the
# shell-smoke filter, including its fail-open handling for missing history.
shell_result="$(bash "$script_dir/should-run-macos-shell-smoke.sh" "$base_sha" "$head_sha" "$repo_root")"
if [[ "$shell_result" == "run=true" ]]; then
  echo "run=true"
  exit 0
fi
if [[ "$shell_result" != "run=false" ]]; then
  echo "unexpected macOS shell filter result: $shell_result" >&2
  exit 2
fi

# The timing run also reads non-shell inputs through the master hook: node
# helpers under core/scripts, settings, every policy tree, and the resumework
# skill whose Bash blocks it replays.
changed_paths="$(git -C "$repo_root" diff --name-only "$base_sha" "$head_sha" -- \
  core/scripts \
  core/settings \
  .claude/hooks \
  .claude/skills/resumework \
  ':(glob)**/policies/**')"

if [[ -n "$changed_paths" ]]; then
  echo "run=true"
else
  echo "run=false"
fi
