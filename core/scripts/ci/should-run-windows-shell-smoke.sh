#!/usr/bin/env bash
# Decide whether a PR changes inputs exercised by Windows shell smoke.
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: should-run-windows-shell-smoke.sh <base-sha> <head-sha> <repo-root>" >&2
  exit 2
fi

base_sha="$1"
head_sha="$2"
repo_root="$3"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep every path selected by the existing shell-smoke filter. The Windows
# job also validates runtime skill metadata and other source inputs, so only
# documentation-only changes outside those surfaces may skip it.
shell_result="$(bash "$script_dir/should-run-macos-shell-smoke.sh" "$base_sha" "$head_sha" "$repo_root")"
if [[ "$shell_result" == "run=true" ]]; then
  echo "run=true"
  exit 0
fi
if [[ "$shell_result" != "run=false" ]]; then
  echo "unexpected macOS shell filter result: $shell_result" >&2
  exit 2
fi

changed_paths="$(git -C "$repo_root" diff --name-only "$base_sha" "$head_sha")"
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  case "$path" in
    docs/*|core/docs/*|core/workers/*/skills/*|README.md|CHANGELOG.md|LICENSE*|CONTRIBUTING.md)
      ;;
    *)
      echo "run=true"
      exit 0
      ;;
  esac
done <<< "$changed_paths"

echo "run=false"
