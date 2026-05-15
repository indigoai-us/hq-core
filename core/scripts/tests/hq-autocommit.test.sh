#!/usr/bin/env bash
# hq-core: public
# Smoke tests for silent HQ-local autosave.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.claude/hooks" "$TMP/core" "$TMP/repos/public/app"
cp "$ROOT/.claude/hooks/hq-autocommit.sh" "$TMP/.claude/hooks/hq-autocommit.sh"
chmod +x "$TMP/.claude/hooks/hq-autocommit.sh"
printf 'hqVersion: "test"\n' > "$TMP/core/core.yaml"

git -C "$TMP" init -q
git -C "$TMP" config user.email "hq-autocommit-test"
git -C "$TMP" config user.name "HQ Autocommit Test"
git -C "$TMP" add core/core.yaml .claude/hooks/hq-autocommit.sh
git -C "$TMP" commit -q -m "init"

printf 'one\n' > "$TMP/notes.md"
payload='{"tool_name":"Edit","tool_input":{"file_path":"notes.md"}}'
(cd "$TMP" && printf '%s' "$payload" | .claude/hooks/hq-autocommit.sh)

git -C "$TMP" show --name-only --format=%s HEAD | grep -q "autosave(hq): notes.md"
git -C "$TMP" show --name-only --format= HEAD | grep -q "^notes.md$"

printf 'repo\n' > "$TMP/repos/public/app/file.txt"
payload_repo='{"tool_name":"Edit","tool_input":{"file_path":"repos/public/app/file.txt"}}'
(cd "$TMP" && printf '%s' "$payload_repo" | .claude/hooks/hq-autocommit.sh)

if git -C "$TMP" show --name-only --format= HEAD | grep -q "repos/public/app/file.txt"; then
  echo "repo path should not be autocommitted" >&2
  exit 1
fi

echo "hq-autocommit smoke: ok"
