#!/usr/bin/env bash
# hq-core: public
# Smoke tests for silent HQ-local autosave.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_PARENT="$(mktemp -d)"
TMP="$TMP_PARENT/hq"
trap 'rm -rf "$TMP_PARENT"' EXIT
mkdir -p "$TMP"

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

REAL_GIT="$(command -v git)"
SHIM_DIR="$TMP/git-shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/git" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

real_git="${HQ_AUTOCOMMIT_TEST_REAL_GIT:?}"
show_toplevel=0
previous=""

for arg in "$@"; do
  if [[ "$previous" == "rev-parse" && "$arg" == "--show-toplevel" ]]; then
    show_toplevel=1
    break
  fi
  previous="$arg"
done

if [[ "$show_toplevel" == "1" ]]; then
  top="$("$real_git" "$@")"
  printf 'C:%s\n' "$top"
else
  exec "$real_git" "$@"
fi
SHIM
chmod +x "$SHIM_DIR/git"

printf 'windows\n' > "$TMP/windows-path.txt"
payload_windows='{"tool_name":"Edit","tool_input":{"file_path":"windows-path.txt"}}'
(
  cd "$TMP"
  export HQ_AUTOCOMMIT_TEST_REAL_GIT="$REAL_GIT"
  export PATH="$SHIM_DIR:$PATH"
  printf '%s' "$payload_windows" | .claude/hooks/hq-autocommit.sh
)

git -C "$TMP" show --name-only --format=%s HEAD | grep -q "autosave(hq): windows-path.txt"
git -C "$TMP" show --name-only --format= HEAD | grep -q "^windows-path.txt$"

mkdir -p "$TMP/workspace/nested"
git -C "$TMP/workspace/nested" init -q
git -C "$TMP/workspace/nested" config user.email "hq-autocommit-test"
git -C "$TMP/workspace/nested" config user.name "HQ Autocommit Test"
printf 'nested\n' > "$TMP/workspace/nested/file.txt"
head_before_nested="$(git -C "$TMP" rev-parse HEAD)"
payload_nested='{"tool_name":"Edit","tool_input":{"file_path":"workspace/nested/file.txt"}}'
(cd "$TMP" && printf '%s' "$payload_nested" | .claude/hooks/hq-autocommit.sh)

if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before_nested" ]]; then
  echo "nested repo path should not be autocommitted" >&2
  exit 1
fi

echo "hq-autocommit smoke: ok"
