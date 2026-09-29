#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir/../../.." rev-parse --show-toplevel)"
linter="$repo_root/core/scripts/lint-shell-errors.sh"
tmp="$(mktemp -d)"
repo="$tmp/repo"
output="$tmp/shellcheck.log"
trap 'rm -rf "$tmp"' EXIT

mkdir "$repo"
git -C "$repo" init --quiet
printf '%s\n' '#!/bin/sh' 'exit 0' > "$repo/valid.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -e' 'exit 0' > "$repo/valid-entrypoint"
git -C "$repo" add -- valid.sh valid-entrypoint

bash "$linter" "$repo" > "$output" 2>&1
grep -F 'ShellCheck checking 2 tracked shell scripts' "$output" >/dev/null

mkdir "$tmp/empty-repo"
git -C "$tmp/empty-repo" init --quiet
bash "$linter" "$tmp/empty-repo" > "$output" 2>&1
grep -F 'ShellCheck checking 0 tracked shell scripts' "$output" >/dev/null

mkdir "$tmp/not-a-repo"
if bash "$linter" "$tmp/not-a-repo" > "$output" 2>&1; then
  printf 'expected tracked-file discovery to fail outside a Git repository\n' >&2
  exit 1
fi
grep -F 'unable to list tracked files' "$output" >/dev/null

expect_rejected() {
  local filename="$1"
  if bash "$linter" "$repo" > "$output" 2>&1; then
    printf 'expected ShellCheck to reject %s\n' "$filename" >&2
    exit 1
  fi
  if ! grep -F "$filename" "$output" >/dev/null; then
    cat "$output" >&2
    printf 'ShellCheck output did not identify %s\n' "$filename" >&2
    exit 1
  fi
}

printf '%s\n' '#!/bin/sh' 'echo "unterminated' > "$repo/bad.sh"
git -C "$repo" add -- bad.sh
expect_rejected bad.sh
git -C "$repo" rm -q --cached -- bad.sh
unlink "$repo/bad.sh"

printf '%s\n' '#!/usr/bin/env bash' 'echo "unterminated' > "$repo/bad-entrypoint"
git -C "$repo" add -- bad-entrypoint
expect_rejected bad-entrypoint

printf 'tracked .sh files and shell shebang entrypoints are linted\n'
