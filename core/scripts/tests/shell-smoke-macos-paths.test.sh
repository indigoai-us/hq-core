#!/usr/bin/env bash
# Prove the shell-smoke filters cover their shared and platform-specific inputs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FILTER="${MACOS_SHELL_FILTER_SCRIPT:-$ROOT/core/scripts/ci/should-run-macos-shell-smoke.sh}"
WINDOWS_FILTER="$ROOT/core/scripts/ci/should-run-windows-shell-smoke.sh"
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

assert_windows_result() {
  local expected="$1"
  local label="$2"
  local base="$3"
  local head="$4"
  local actual
  actual="$(bash "$WINDOWS_FILTER" "$base" "$head" "$FIXTURE")"
  if [[ "$actual" != "run=$expected" ]]; then
    echo "FAIL: Windows $label expected run=$expected, got: $actual" >&2
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
doc_head="$(git -C "$FIXTURE" rev-parse HEAD)"
doc_base="$(git -C "$FIXTURE" rev-parse HEAD^)"
assert_windows_result false 'documentation-only change' "$doc_base" "$doc_head"
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
assert_windows_result true 'missing base history fails open' '0000000000000000000000000000000000000000' "$head"

if [[ ! -x "$WINDOWS_FILTER" ]]; then
  echo 'FAIL: Windows filter must include agent runtime metadata inputs before the job can be skipped' >&2
  exit 1
fi

base="$(git -C "$FIXTURE" rev-parse HEAD)"
mkdir -p "$FIXTURE/.claude/skills/fixture"
printf '%s\n' '# skill metadata' > "$FIXTURE/.claude/skills/fixture/SKILL.md"
commit_fixture 'change root skill metadata'
head="$(git -C "$FIXTURE" rev-parse HEAD)"
assert_single_path "$base" "$head" '.claude/skills/fixture/SKILL.md'
assert_result false 'root skill metadata is outside the macOS shell inputs' "$base" "$head"
assert_windows_result true 'root skill metadata triggers runtime contract validation' "$base" "$head"

base="$head"
mkdir -p "$FIXTURE/core/packages/fixture/skills/example/agents"
printf '%s\n' 'name: fixture' 'contributes:' '  skills:' '    - example' > "$FIXTURE/core/packages/fixture/package.yaml"
commit_fixture 'change package manifest'
head="$(git -C "$FIXTURE" rev-parse HEAD)"
assert_single_path "$base" "$head" 'core/packages/fixture/package.yaml'
assert_result false 'package manifest is outside the macOS shell inputs' "$base" "$head"
assert_windows_result true 'package manifest triggers runtime contract validation' "$base" "$head"

base="$head"
printf '%s\n' 'interface:' '  display_name: Fixture' > "$FIXTURE/core/packages/fixture/skills/example/agents/openai.yaml"
commit_fixture 'change package skill OpenAI metadata'
head="$(git -C "$FIXTURE" rev-parse HEAD)"
assert_single_path "$base" "$head" 'core/packages/fixture/skills/example/agents/openai.yaml'
assert_result false 'package OpenAI metadata is outside the macOS shell inputs' "$base" "$head"
assert_windows_result true 'package OpenAI metadata triggers runtime contract validation' "$base" "$head"

base="$head"
mkdir -p "$FIXTURE/core/scripts"
printf '%s\n' 'export const validate = true;' > "$FIXTURE/core/scripts/validate-agent-runtime-contracts.mjs"
commit_fixture 'change runtime validator source'
head="$(git -C "$FIXTURE" rev-parse HEAD)"
assert_single_path "$base" "$head" 'core/scripts/validate-agent-runtime-contracts.mjs'
assert_result false 'runtime validator source is outside the macOS shell inputs' "$base" "$head"
assert_windows_result true 'runtime validator source triggers Windows smoke' "$base" "$head"

base="$head"
mkdir -p "$FIXTURE/core/workers/public/setup/skills"
printf '%s\n' '# setup worker content' > "$FIXTURE/core/workers/public/setup/skills/agents-and-team.md"
commit_fixture 'change worker skill documentation'
head="$(git -C "$FIXTURE" rev-parse HEAD)"
assert_single_path "$base" "$head" 'core/workers/public/setup/skills/agents-and-team.md'
assert_result false 'worker skill content is outside the macOS shell inputs' "$base" "$head"
assert_windows_result false 'worker skill documentation does not affect shell smoke' "$base" "$head"

WORKFLOW="$ROOT/.github/workflows/pr-checks.yml"
windows_detection_step="$(sed -n '/id: shell_smoke_windows_paths/,/GITHUB_OUTPUT/p' "$WORKFLOW")"
if ! grep -Fq 'should-run-windows-shell-smoke.sh' <<< "$windows_detection_step"; then
  echo 'FAIL: denylist-scan must run the Windows-specific path detector' >&2
  exit 1
fi
if ! grep -Fq "windows_shell_smoke: \${{ steps.shell_smoke_windows_paths.outputs.run }}" "$WORKFLOW"; then
  echo 'FAIL: denylist-scan must expose the Windows shell-smoke path decision' >&2
  exit 1
fi

windows_job="$(sed -n '/^  shell-smoke-windows:$/,/^  shell-smoke-macos:$/p' "$WORKFLOW")"
if ! grep -Fqx '    needs: [denylist-scan]' <<< "$windows_job"; then
  echo 'FAIL: shell-smoke-windows must wait for denylist-scan path detection' >&2
  exit 1
fi
if ! grep -Fq "|| needs['denylist-scan'].outputs.windows_shell_smoke == 'true')" <<< "$windows_job"; then
  echo 'FAIL: shell-smoke-windows must use the Windows relevant-path output for pull requests' >&2
  exit 1
fi
if ! grep -Fq '!cancelled()' <<< "$windows_job"; then
  echo 'FAIL: shell-smoke-windows must honor cancellation while evaluating fail-open conditions' >&2
  exit 1
fi
if grep -Fq 'always()' <<< "$windows_job"; then
  echo 'FAIL: shell-smoke-windows must not override workflow cancellation' >&2
  exit 1
fi
if ! grep -Fq "needs['denylist-scan'].result != 'success'" <<< "$windows_job"; then
  echo 'FAIL: shell-smoke-windows must run when the Windows detector is missing or unsuccessful' >&2
  exit 1
fi
if ! grep -Fq "github.event_name == 'push'" <<< "$windows_job"; then
  echo 'FAIL: shell-smoke-windows must remain unconditional on main pushes' >&2
  exit 1
fi
if ! grep -Fq 'bash core/scripts/tests/session-title-windows-argv.test.sh' <<< "$windows_job"; then
  echo 'FAIL: shell-smoke-windows must execute the Git Bash session-title argv regression' >&2
  exit 1
fi

# --- resumework-timing-linux path filter ---------------------------------
RESUMEWORK_FILTER="$ROOT/core/scripts/ci/should-run-resumework-timing.sh"
if [[ ! -x "$RESUMEWORK_FILTER" ]]; then
  echo 'FAIL: resumework timing filter must exist and be executable' >&2
  exit 1
fi

assert_resumework_result() {
  local expected="$1" label="$2" base="$3" head="$4" actual
  actual="$(bash "$RESUMEWORK_FILTER" "$base" "$head" "$FIXTURE")"
  if [[ "$actual" != "run=$expected" ]]; then
    echo "FAIL: resumework $label expected run=$expected, got: $actual" >&2
    exit 1
  fi
}

resumework_case() {
  local path="$1" label="$2" expected="$3" base head
  base="$(git -C "$FIXTURE" rev-parse HEAD)"
  mkdir -p "$(dirname "$FIXTURE/$path")"
  printf '%s\n' "$label" > "$FIXTURE/$path"
  commit_fixture "$label"
  head="$(git -C "$FIXTURE" rev-parse HEAD)"
  assert_single_path "$base" "$head" "$path"
  assert_resumework_result "$expected" "$label" "$base" "$head"
}

assert_resumework_result false 'documentation-only change' "$doc_base" "$doc_head"
assert_resumework_result true 'missing base history fails open' '0000000000000000000000000000000000000000' "$(git -C "$FIXTURE" rev-parse HEAD)"
resumework_case 'tools/timing-input.sh' 'shell source' true
resumework_case 'core/policies/example-rule.md' 'core policy' true
resumework_case 'companies/acme/policies/acme-rule.md' 'company policy' true
resumework_case 'personal/policies/own-rule.md' 'personal policy' true
resumework_case '.claude/skills/resumework/SKILL.md' 'resumework skill' true
resumework_case 'core/settings/intent-index.yaml' 'core settings' true
resumework_case 'core/scripts/derive-helper.mjs' 'node helper under core/scripts' true
resumework_case '.claude/skills/other-skill/SKILL.md' 'unrelated skill' false
resumework_case 'core/knowledge/public/notes.md' 'knowledge page' false

resumework_detection_step="$(sed -n '/id: resumework_timing_paths/,/GITHUB_OUTPUT/p' "$WORKFLOW")"
if ! grep -Fq 'should-run-resumework-timing.sh' <<< "$resumework_detection_step"; then
  echo 'FAIL: denylist-scan must run the resumework timing path detector' >&2
  exit 1
fi
if ! grep -Fq "resumework_timing: \${{ steps.resumework_timing_paths.outputs.run }}" "$WORKFLOW"; then
  echo 'FAIL: denylist-scan must expose the resumework timing path decision' >&2
  exit 1
fi
resumework_job="$(awk '
  /^  resumework-timing-linux:$/ { in_job=1; print; next }
  in_job && /^  [[:alnum:]_-]+:$/ { exit }
  in_job { print }
' "$WORKFLOW")"
for required in \
  '    needs: [denylist-scan]' \
  '!cancelled()' \
  "github.event_name == 'push'" \
  "needs['denylist-scan'].result != 'success'" \
  "needs['denylist-scan'].outputs.resumework_timing == 'true'" \
  "RESUMEWORK_TIMING_RUNS: '20'" \
  'run: bash core/scripts/tests/resumework-timing.test.sh'; do
  if ! grep -Fq -- "$required" <<< "$resumework_job"; then
    echo "FAIL: resumework-timing-linux must keep: $required" >&2
    exit 1
  fi
done
if grep -Fq 'always()' <<< "$resumework_job"; then
  echo 'FAIL: resumework-timing-linux must not override workflow cancellation' >&2
  exit 1
fi

echo 'ALL PASS: shell-smoke-macos-paths'
