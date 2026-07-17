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
cat > "$SHIM_DIR/python3" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
chmod +x "$SHIM_DIR/python3"

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

# A file under workspace/worktrees/ (a live project worktree) is never autosaved
# into the HQ root. (feedback_2ada615f)
mkdir -p "$TMP/workspace/worktrees/proj"
printf 'wt\n' > "$TMP/workspace/worktrees/proj/notes.md"
head_before_wt="$(git -C "$TMP" rev-parse HEAD)"
payload_wt='{"tool_name":"Edit","tool_input":{"file_path":"workspace/worktrees/proj/notes.md"}}'
(cd "$TMP" && printf '%s' "$payload_wt" | .claude/hooks/hq-autocommit.sh)

if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before_wt" ]]; then
  echo "workspace/worktrees path should not be autocommitted" >&2
  exit 1
fi

# Gitlink guard: a directory add that would sweep a nested repo into the HQ root
# as an embedded gitlink (mode 160000) is refused — no commit, nothing staged.
# (feedback_2ada615f)
mkdir -p "$TMP/holder/inner"
git -C "$TMP/holder/inner" init -q
git -C "$TMP/holder/inner" config user.email "hq-autocommit-test"
git -C "$TMP/holder/inner" config user.name "HQ Autocommit Test"
printf 'inner\n' > "$TMP/holder/inner/f.txt"
git -C "$TMP/holder/inner" add -A
git -C "$TMP/holder/inner" commit -q -m "inner"
printf 'plain\n' > "$TMP/holder/plain.txt"
head_before_gitlink="$(git -C "$TMP" rev-parse HEAD)"
payload_gitlink='{"tool_name":"Edit","tool_input":{"file_path":"holder"}}'
(cd "$TMP" && printf '%s' "$payload_gitlink" | .claude/hooks/hq-autocommit.sh)

if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before_gitlink" ]]; then
  echo "directory add sweeping a gitlink should not be autocommitted" >&2
  exit 1
fi
if git -C "$TMP" ls-files --stage | awk '$1 == "160000" { exit 0 } END { exit 1 }'; then
  echo "gitlink (mode 160000) must not remain staged in the HQ root" >&2
  exit 1
fi

echo "hq-autocommit smoke: ok"
