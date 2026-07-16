#!/usr/bin/env bash
# Regression coverage for worktree provisioning and gate runner failures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/run-project.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

assert_contains() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == *"$expected"* ]] || fail "$label: expected '$expected' in '$actual'"
}

assert_not_contains() {
  local actual="$1" unexpected="$2" label="$3"
  [[ "$actual" != *"$unexpected"* ]] || fail "$label: did not expect '$unexpected' in '$actual'"
}

emit_function() {
  local name="$1"
  awk -v name="$name" '
    $0 ~ ("^" name "\\(\\) \\{") { found=1 }
    found {
      print
      if ($0 ~ /^}$/) exit
    }
  ' "$SCRIPT"
}

# Exercise the functions from the real script without entering its CLI loop.
{
  emit_function is_git_repo
  emit_function provision_worktree
  emit_function ensure_worktree
  emit_function ensure_missing_repo_worktree
  emit_function ensure_story_worktree
  emit_function is_gate_execution_error
  emit_function run_regression_gate
} > "$TMP/run-project-functions.sh"

# shellcheck source=/dev/null
source "$TMP/run-project-functions.sh"

log() { printf '%s\n' "$*"; }
log_info() { printf '%s\n' "$*"; }
log_ok() { printf '%s\n' "$*"; }
log_warn() { printf '%s\n' "$*"; }
log_err() { printf '%s\n' "$*"; }
ts() { printf '2026-01-01T00:00:00Z\n'; }

BIN="$TMP/bin"
PM_LOG="$TMP/package-managers.log"
mkdir -p "$BIN"
export PM_LOG

for package_manager in pnpm bun npm; do
  cat > "$BIN/$package_manager" <<'SH'
#!/usr/bin/env bash
name="${0##*/}"
printf '%s %s\n' "$name" "$*" >> "$PM_LOG"
case "$name" in
  pnpm) exit "${PNPM_EXIT:-0}" ;;
  bun) exit "${BUN_EXIT:-0}" ;;
  npm) exit "${NPM_EXIT:-0}" ;;
esac
SH
  chmod +x "$BIN/$package_manager"
done

PATH="$BIN:$PATH"

make_repo() {
  local repo="$1"
  shift
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name 'Run Project Test'
  printf 'fixture\n' > "$repo/README.md"
  local lockfile
  for lockfile in "$@"; do
    printf 'lock\n' > "$repo/$lockfile"
  done
  git -C "$repo" add README.md "$@"
  git -C "$repo" commit -qm 'fixture'
}

# Standard project worktree: pnpm wins over Bun/npm and copies untracked .npmrc.
normal_repo="$TMP/normal"
make_repo "$normal_repo" pnpm-lock.yaml bun.lock package-lock.json
printf '@private:registry=https://registry.example.test\n' > "$normal_repo/.npmrc"
: > "$PM_LOG"
REPO_PATH="$normal_repo"
ensure_worktree "$normal_repo" 'feature/normal' main
normal_wt="${normal_repo}-wt-feature-normal"
assert_eq "$(cat "$PM_LOG")" 'pnpm install --frozen-lockfile' 'normal worktree uses pnpm before Bun and npm'
assert_eq "$(cat "$normal_wt/.npmrc")" '@private:registry=https://registry.example.test' 'normal worktree copies untracked .npmrc'

# repoPath-missing fallback: Bun is selected when no pnpm lockfile exists.
fallback_repo="$TMP/fallback"
make_repo "$fallback_repo" bun.lock
printf 'registry=https://registry.example.test\n' > "$fallback_repo/.npmrc"
fallback_wt="${fallback_repo}-feature"
: > "$PM_LOG"
ensure_missing_repo_worktree "$fallback_wt" 'feature/fallback' main
assert_eq "$(cat "$PM_LOG")" 'bun install --frozen-lockfile' 'missing repoPath worktree uses Bun'
assert_eq "$(cat "$fallback_wt/.npmrc")" 'registry=https://registry.example.test' 'missing repoPath worktree copies .npmrc'

# Per-story swarm worktree: npm remains the fallback when it is the only lockfile.
story_repo="$TMP/story"
make_repo "$story_repo" package-lock.json
printf 'registry=https://registry.example.test\n' > "$story_repo/.npmrc"
REPO_PATH="$story_repo"
ORIGINAL_REPO_PATH=""
BRANCH_NAME='feature/story'
BASE_BRANCH=main
: > "$PM_LOG"
ensure_story_worktree 'US_001'
story_wt="${story_repo}-wt-feature-story-us-001"
assert_eq "$(cat "$PM_LOG")" 'npm ci' 'story worktree uses npm when it is the only lockfile'
assert_eq "$(cat "$story_wt/.npmrc")" 'registry=https://registry.example.test' 'story worktree copies .npmrc'

# A failed install is a bootstrap failure, not a successful worktree with no deps.
failing_repo="$TMP/failing"
make_repo "$failing_repo" pnpm-lock.yaml
: > "$PM_LOG"
export PNPM_EXIT=19
if failure_output=$(ensure_worktree "$failing_repo" 'feature/failing' main 2>&1); then
  fail 'failed pnpm install should fail worktree bootstrap'
fi
unset PNPM_EXIT
assert_contains "$failure_output" 'Worktree bootstrap failed' 'failed install is explicit'
assert_eq "$(cat "$PM_LOG")" 'pnpm install --frozen-lockfile' 'failed install still uses frozen pnpm'

# A missing package manager is an explicit bootstrap precondition failure.
missing_pm_source="$TMP/missing-pm-source"
missing_pm_wt="$TMP/missing-pm-worktree"
mkdir -p "$missing_pm_source" "$missing_pm_wt"
printf 'lock\n' > "$missing_pm_wt/pnpm-lock.yaml"
saved_path="$PATH"
PATH="$TMP/no-package-manager:/usr/bin:/bin"
if missing_pm_output=$(provision_worktree "$missing_pm_source" "$missing_pm_wt" 2>&1); then
  fail 'missing pnpm should fail worktree bootstrap'
fi
PATH="$saved_path"
assert_contains "$missing_pm_output" 'bootstrap precondition failed' 'missing manager is explicit'

# A missing test runner is an execution precondition error, not a numeric test regression.
PROJECT_DIR="$TMP/regression-project"
REPO_PATH="$TMP/regression-repo"
PRD_PATH="$PROJECT_DIR/prd.json"
STATE_FILE="$PROJECT_DIR/state.json"
ORIGINAL_REPO_PATH=""
mkdir -p "$PROJECT_DIR" "$REPO_PATH"
printf '%s\n' '{"metadata":{"qualityGates":["missing-test-runner"]}}' > "$PRD_PATH"
printf '%s\n' '{"status":"in_progress","regression_gates":[]}' > "$STATE_FILE"
PATH="$TMP/no-test-runner:/usr/bin:/bin"
if gate_output=$(run_regression_gate 'US-001' 2>&1); then
  fail 'missing test runner should fail the regression gate precondition'
else
  gate_status=$?
fi
PATH="$saved_path"
assert_eq "$gate_status" '127' 'missing runner preserves shell exit status'
assert_contains "$gate_output" 'PRECONDITION ERROR' 'missing runner is classified as a precondition error'
assert_contains "$gate_output" 'exit=127' 'precondition error reports runner exit status'
assert_not_contains "$gate_output" 'REGRESSION:' 'missing runner is not a numeric regression'
assert_not_contains "$gate_output" 'auto-pausing' 'missing runner does not use ordinary regression auto-pause'
assert_eq "$(jq -r '.status' "$STATE_FILE")" 'in_progress' 'missing runner does not pause project state'

echo 'run-project worktree provisioning and regression-gate tests passed'
