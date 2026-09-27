#!/usr/bin/env bash
# Prove the macOS shell-smoke filter covers each path exercised by its tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FILTER="${MACOS_SHELL_FILTER_SCRIPT:-$ROOT/core/scripts/ci/should-run-macos-shell-smoke.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/shell-smoke-macos-paths.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP/global-gitconfig"
: > "$GIT_CONFIG_GLOBAL"
unset GIT_DIR GIT_WORK_TREE || true

FIXTURE="$TMP/repo"
mkdir -p "$FIXTURE"
git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config core.filemode true
printf 'initial\n' > "$FIXTURE/README.md"
printf '#!/usr/bin/env bash\ntrue\n' > "$FIXTURE/mode-only.sh"
chmod 0644 "$FIXTURE/mode-only.sh"
git -C "$FIXTURE" add README.md mode-only.sh
git -C "$FIXTURE" -c user.name=GH2-test -c user.email=gh2-test@example.invalid \
  -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm initial

commit_fixture() {
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" -c user.name=GH2-test -c user.email=gh2-test@example.invalid \
    -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm "$1"
}

assert_single_path() {
  local base="$1"
  local head="$2"
  local expected_path="$3"
  local changed_paths
  changed_paths="$(git -C "$FIXTURE" diff --name-only "$base" "$head")"
  if [[ "$changed_paths" != "$expected_path" ]]; then
    echo "FAIL: test case must change only $expected_path, got: $changed_paths" >&2
    exit 1
  fi
}

assert_result() {
  local expected="$1"
  local label="$2"
  local base="$3"
  local head="$4"
  local actual
  actual="$(bash "$FILTER" "$base" "$head" "$FIXTURE")"
  if [[ "$actual" != "run=$expected" ]]; then
    echo "FAIL: $label expected run=$expected, got: $actual" >&2
    exit 1
  fi
}

commit_and_assert() {
  local label="$1"
  local expected="$2"
  local changed_path="$3"
  local base head
  base="$(git -C "$FIXTURE" rev-parse HEAD)"
  commit_fixture "$label"
  head="$(git -C "$FIXTURE" rev-parse HEAD)"
  assert_single_path "$base" "$head" "$changed_path"
  assert_result "$expected" "$label" "$base" "$head"
}

write_case() {
  local path="$1"
  local contents="$2"
  local label="$3"
  local expected="$4"
  mkdir -p "$(dirname "$FIXTURE/$path")"
  printf '%s' "$contents" > "$FIXTURE/$path"
  commit_and_assert "$label" "$expected" "$path"
}

write_case 'docs/guide.md' $'unrelated documentation\n' 'unrelated documentation' false
write_case 'nested/scripts/change.sh' $'#!/usr/bin/env bash\ntrue\n' 'nested shell source' true
write_case 'root-check.sh' $'#!/usr/bin/env bash\ntrue\n' 'root shell source' true
write_case 'nested/scripts/change.bash' $'#!/usr/bin/env bash\ntrue\n' 'bash source' true
write_case 'nested/scripts/change.bats' $'# bats test\n' 'bats source' true
write_case '.github/workflows/pr-checks.yml' $'name: pr-checks\n' 'workflow change' true

write_case '.claude/settings.json' $'{}\n' 'settings.json input' true
write_case '.claude/hooks/hook-registry.json' $'{}\n' 'hook registry input' true
write_case '.claude/hooks/block-agent-secrets-reveal-flag.cjs' $'module.exports = {};\n' 'CJS hook input' true
write_case '.grok/hooks/hq-grok.json' $'{}\n' 'Grok hook registry input' true
write_case '.grok/hooks/hq-grok-user-bridge.json' $'{}\n' 'Grok bridge input' true
write_case 'core/core.yaml' $'hqVersion: "15.0.0"\n' 'core config input' true
write_case '.claude/skills/deploy/SKILL.md' $'# Deploy skill\n' 'deploy skill input' true
write_case 'core/scripts/lib/portable.sh' $'#!/usr/bin/env bash\ntrue\n' 'shared shell library input' true

# The file content and path are unchanged; this range contains only the mode.
base="$(git -C "$FIXTURE" rev-parse HEAD)"
chmod +x "$FIXTURE/mode-only.sh"
commit_fixture 'make shell smoke input executable'
head="$(git -C "$FIXTURE" rev-parse HEAD)"
assert_single_path "$base" "$head" 'mode-only.sh'
mode_summary="$(git -C "$FIXTURE" diff --summary "$base" "$head" -- mode-only.sh)"
if [[ "$mode_summary" != *'mode change 100644 => 100755'* ]]; then
  echo "FAIL: chmod case was not mode-only: $mode_summary" >&2
  exit 1
fi
numstat="$(git -C "$FIXTURE" diff --numstat "$base" "$head" -- mode-only.sh)"
read -r added_lines removed_lines changed_path <<< "$numstat"
if [[ "$added_lines" != 0 || "$removed_lines" != 0 || "$changed_path" != mode-only.sh ]]; then
  echo "FAIL: chmod case changed file contents: $numstat" >&2
  exit 1
fi
assert_result true 'chmod-only shell change' "$base" "$head"

base="$(git -C "$FIXTURE" rev-parse HEAD)"
git -C "$FIXTURE" rm -q nested/scripts/change.sh
commit_fixture 'remove shell source'
head="$(git -C "$FIXTURE" rev-parse HEAD)"
assert_single_path "$base" "$head" 'nested/scripts/change.sh'
assert_result true 'removed shell source' "$base" "$head"

assert_result true 'missing base history fails open' '0000000000000000000000000000000000000000' "$head"

echo 'ALL PASS: shell-smoke-macos-paths'
