#!/usr/bin/env bash
# A run-project dry run prints today's execution order without changing project
# files or creating, registering, or cleaning up a git worktree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${HQ_TEST_RUN_PROJECT_SCRIPT:-$ROOT/.claude/scripts/run-project.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

assert_same_file() {
  local before="$1" after="$2" label="$3"
  if ! cmp -s "$before" "$after"; then
    fail "$label changed during dry run"
    diff -u "$before" "$after" >&2 || true
  fi
}

snapshot_path() {
  local path="$1" name="$2"
  if [[ -e "$path" ]]; then
    cp -R "$path" "$TMP/$name.snapshot"
  else
    : > "$TMP/$name.absent"
  fi
}

assert_snapshot_unchanged() {
  local path="$1" name="$2"
  if [[ -e "$TMP/$name.absent" ]]; then
    [[ ! -e "$path" ]] || fail "$name was created during dry run"
  elif [[ ! -e "$path" ]]; then
    fail "$name was removed during dry run"
  elif [[ -d "$path" ]]; then
    diff -ru "$TMP/$name.snapshot" "$path" >/dev/null \
      || { fail "$name changed during dry run"; diff -ru "$TMP/$name.snapshot" "$path" >&2 || true; }
  else
    assert_same_file "$TMP/$name.snapshot" "$path" "$name"
  fi
}

HQ_FIXTURE="$TMP/hq"
PROJECT="dry-run-fixture"
PROJECT_DIR="$HQ_FIXTURE/workspace/orchestrator/$PROJECT"
REPO="$HQ_FIXTURE/repos/demo"
mkdir -p "$HQ_FIXTURE/core/scripts/lib" "$HQ_FIXTURE/core/scripts" \
  "$HQ_FIXTURE/core/settings" "$HQ_FIXTURE/personal/projects/$PROJECT" \
  "$HQ_FIXTURE/workspace/orchestrator" "$REPO"
cp "$ROOT/core/scripts/lib/detect-codex.sh" "$HQ_FIXTURE/core/scripts/lib/detect-codex.sh"

REGISTRY_LOG="$HQ_FIXTURE/workspace/orchestrator/repo-run-registry.log"
# US-043: run-project.sh calls hq core repo-run-registry and hq core
# audit-log. The stub hq records every call into the logs the dry run must not
# touch.
cp "$ROOT/core/scripts/lib/hq-cli-floor.sh" "$HQ_FIXTURE/core/scripts/lib/hq-cli-floor.sh"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--version" ]] && { printf '%s\n' 9.9.9; exit 0; }
case " $* " in
  *" repo-run-registry "*)
    printf '%s\n' "$*" >> "$HQ_ROOT/workspace/orchestrator/repo-run-registry.log"
    [[ " $* " == *" register "* ]] && printf '%s\n' 'fixture-run-id'
    ;;
  *" audit-log "*) printf '%s\n' "$*" >> "$HQ_ROOT/workspace/orchestrator/audit.log" ;;
esac
exit 0
SH
chmod +x "$TMP/bin/hq"
cat > "$HQ_FIXTURE/core/settings/orchestrator.yaml" <<'YAML'
worktree:
  enabled: true
checkout:
  enabled: true
YAML

git() {
  case " $* " in
    *" worktree add "*) printf '%s\n' add >> "$GIT_WORKTREE_EVENTS" ;;
    *" worktree remove "*) printf '%s\n' remove >> "$GIT_WORKTREE_EVENTS" ;;
  esac
  command git "$@"
}

git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name='Dry Run Test' -c user.email='dry-run@example.invalid' \
  commit --allow-empty -m 'fixture base' >/dev/null

cat > "$HQ_FIXTURE/personal/projects/$PROJECT/prd.json" <<'JSON'
{
  "branchName": "fixture/dry-run",
  "metadata": {"repoPath": "repos/demo", "baseBranch": "main"},
  "userStories": [
    {"id": "S1", "title": "First", "description": "First story", "passes": false},
    {"id": "S2", "title": "Second", "description": "Second story", "passes": false, "dependsOn": ["S1"]},
    {"id": "S3", "title": "Third", "description": "Third story", "passes": false}
  ]
}
JSON

STATE_FILE="$PROJECT_DIR/state.json"
PROGRESS_FILE="$PROJECT_DIR/progress.txt"
AUDIT_FILE="$HQ_FIXTURE/workspace/orchestrator/audit.log"
mkdir -p "$PROJECT_DIR"
cat > "$STATE_FILE" <<'JSON'
{
  "project": "dry-run-fixture",
  "status": "in_progress",
  "updated_at": "2000-01-01T00:00:00Z",
  "progress": {"total": 3, "completed": 1, "failed": 0, "in_progress": 1},
  "current_task": {"id": "legacy-task", "pid": null},
  "completed_tasks": ["S1"]
}
JSON
printf '%s\n' 'progress before' > "$PROGRESS_FILE"
printf '%s\n' 'audit before' > "$AUDIT_FILE"
: > "$REGISTRY_LOG"
snapshot_path "$STATE_FILE" state
snapshot_path "$PROGRESS_FILE" progress
snapshot_path "$AUDIT_FILE" audit
snapshot_path "$REGISTRY_LOG" registry
command git -C "$REPO" worktree list --porcelain > "$TMP/worktrees.before"

export GIT_WORKTREE_EVENTS="$TMP/worktree-events"
export -f git

set +e
env \
  -u CODEX_SESSION_ID -u CODEX_SANDBOX -u CODEX_EXECUTION_ID -u CODEX_AGENT_ID -u OPENAI_CODEX \
  HQ_ROOT="$HQ_FIXTURE" \
  HOME="$TMP" \
  PATH="$TMP/bin:$PATH" \
  HQ_TEST_RUN_PROJECT_SCRIPT="$SCRIPT" \
  bash -x "$SCRIPT" "$PROJECT" --dry-run \
  > "$TMP/output" 2> "$TMP/trace"
run_status=$?
set -e

command git -C "$REPO" worktree list --porcelain > "$TMP/worktrees.after"
assert_snapshot_unchanged "$STATE_FILE" state
assert_snapshot_unchanged "$PROGRESS_FILE" progress
assert_snapshot_unchanged "$AUDIT_FILE" audit
assert_snapshot_unchanged "$REGISTRY_LOG" registry
assert_same_file "$TMP/worktrees.before" "$TMP/worktrees.after" 'git worktree list'

[[ "$run_status" -eq 0 ]] || fail "dry run exited $run_status"
if [[ "$run_status" -ne 0 ]]; then
  cat "$TMP/output" "$TMP/trace" >&2
fi
[[ ! -s "$GIT_WORKTREE_EVENTS" ]] || fail "dry run invoked git worktree add/remove: $(cat "$GIT_WORKTREE_EVENTS")"
if grep -Eq 'trap .*cleanup_worktree' "$TMP/trace"; then
  fail "dry run installed a cleanup trap"
fi
[[ ! -e "$HQ_FIXTURE/workspace/worktrees/demo/fixture-dry-run" ]] || fail "dry run created a worktree directory"
if command git -C "$REPO" show-ref --verify --quiet refs/heads/fixture/dry-run; then
  fail "dry run created the fixture branch"
fi
[[ ! -e "$PROJECT_DIR/executions" ]] || fail "dry run created the executions directory"

actual_order="$(sed -n '/Dry Run — Story Execution Order:/,$p' "$TMP/output" \
  | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g; /Cleaning up worktree:/d')"
expected_order=$'Dry Run — Story Execution Order:\n\n  1. S1: First\n  2. S2: Second (after: S1)\n  3. S3: Third'
[[ "$actual_order" == "$expected_order" ]] || {
  fail "dry-run execution order changed"
  diff -u <(printf '%s\n' "$expected_order") <(printf '%s\n' "$actual_order") >&2 || true
}

if [[ "$failures" -gt 0 ]]; then
  echo "run-project dry-run no-write test failed ($failures assertions)" >&2
  exit 1
fi

# US-043: outside a dry run the helpers reach hq core with the run's root.
helpers="$TMP/run-project-helpers.sh"
sed -n -e '/^audit_log() {$/,/^}$/p' -e '/^repo_run_registry() {$/,/^}$/p' "$SCRIPT" > "$helpers"
[[ "$(grep -c '^}$' "$helpers")" == 2 ]] || { echo "FAIL: audit_log/repo_run_registry not found in $SCRIPT" >&2; exit 1; }
: > "$REGISTRY_LOG"; : > "$AUDIT_FILE"
(
  export HOME="$TMP" PATH="$TMP/bin:$PATH" HQ_ROOT="$HQ_FIXTURE"
  # shellcheck source=/dev/null
  . "$helpers"
  [[ "$(repo_run_registry register --repo demo)" == fixture-run-id ]] || exit 1
  audit_log append --event project_started --project "$PROJECT" || exit 1
) || { echo "FAIL: run-project helpers did not reach hq core" >&2; exit 1; }
grep -qxF "core --hq-root $HQ_FIXTURE repo-run-registry register --repo demo" "$REGISTRY_LOG" \
  || { echo "FAIL: repo-run-registry call: $(cat "$REGISTRY_LOG")" >&2; exit 1; }
grep -qxF "core --hq-root $HQ_FIXTURE audit-log append --event project_started --project $PROJECT" "$AUDIT_FILE" \
  || { echo "FAIL: audit-log call: $(cat "$AUDIT_FILE")" >&2; exit 1; }

echo "run-project dry-run no-write test passed"
