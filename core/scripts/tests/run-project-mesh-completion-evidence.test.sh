#!/usr/bin/env bash
# A completed work-mesh note requires all stories to pass and, when a project
# has a configured repository branch, at least one commit ahead of its base.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WRAPPER="${HQ_TEST_RUN_PROJECT_WRAPPER:-$ROOT/core/scripts/run-project.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

FIX="$TMP/hq"
REPO="$FIX/repos/demo"
mkdir -p "$FIX/core/scripts" "$FIX/.claude/scripts" "$FIX/bin" \
  "$FIX/companies/acme/projects/widget" "$REPO" "$TMP/home"
cp "$WRAPPER" "$FIX/core/scripts/run-project.sh"
cat > "$FIX/.claude/scripts/run-project.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
case "${MESH_CHILD_ACTION:-}" in
  commit-repo)
    git -C "$MESH_CHILD_REPO" -c user.name='Mesh Test' -c user.email='mesh@example.invalid' \
      commit --allow-empty -m 'delivery on base branch' >/dev/null
    ;;
  create-temp-worktree)
    git -C "$MESH_CHILD_REPO" worktree add -q -b "$MESH_CHILD_BRANCH" \
      "$MESH_CHILD_TARGET" "$MESH_CHILD_BASE"
    git -C "$MESH_CHILD_TARGET" -c user.name='Mesh Test' -c user.email='mesh@example.invalid' \
      commit --allow-empty -m 'temporary worktree delivery' >/dev/null
    git -C "$MESH_CHILD_REPO" worktree remove "$MESH_CHILD_TARGET"
    ;;
esac
CHILD
chmod +x "$FIX/.claude/scripts/run-project.sh"
cat > "$FIX/bin/hq" <<'HQ'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MESH_LOG"
HQ
chmod +x "$FIX/bin/hq"

git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name='Mesh Test' -c user.email='mesh@example.invalid' \
  commit --allow-empty -m 'base' >/dev/null
git -C "$REPO" branch feature/work

write_prd() {
  local repo_path="$1" branch="$2" base="$3"
  cat > "$FIX/companies/acme/projects/widget/prd.json" <<JSON
{
  "name": "widget",
  "branchName": "$branch",
  "metadata": {"repoPath": "$repo_path", "baseBranch": "$base"},
  "userStories": [{"id": "US-1", "passes": true}]
}
JSON
}
write_prd repos/demo feature/work main

export MESH_LOG="$TMP/mesh.log"
run_wrapper() {
  local action="${1:-}" branch="${2:-}" target="${3:-}" base="${4:-main}"
  : > "$MESH_LOG"
  env -i PATH="$FIX/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TMP/home" \
    MESH_LOG="$MESH_LOG" HQ_SESSION_ID=sess_test \
    MESH_CHILD_ACTION="$action" MESH_CHILD_REPO="$REPO" \
    MESH_CHILD_BRANCH="$branch" MESH_CHILD_TARGET="$target" MESH_CHILD_BASE="$base" \
    bash "$FIX/core/scripts/run-project.sh" widget >/dev/null 2>&1
}

run_wrapper || fail 'wrapper with a zero-commit branch must exit 0'
grep -Fq -- '--summary run-project made progress on widget' "$MESH_LOG" \
  || fail 'zero-commit branch must be reported as progress, not completion'
if grep -Fq -- '--summary run-project completed for widget' "$MESH_LOG"; then
  fail 'zero-commit branch was reported complete'
fi

git -C "$REPO" checkout -q feature/work
git -C "$REPO" -c user.name='Mesh Test' -c user.email='mesh@example.invalid' \
  commit --allow-empty -m 'delivery evidence' >/dev/null
run_wrapper || fail 'wrapper with a committed branch must exit 0'
grep -Fq -- '--summary run-project completed for widget' "$MESH_LOG" \
  || fail 'a passing project with a branch commit must still be reported complete'

git -C "$REPO" checkout -q main
write_prd repos/demo main main
run_wrapper || fail 'wrapper with no new base-branch commit must exit 0'
grep -Fq -- '--summary run-project made progress on widget' "$MESH_LOG" \
  || fail 'a passing run with no new base-branch commit must remain progress'
if grep -Fq -- '--summary run-project completed for widget' "$MESH_LOG"; then
  fail 'a base branch with no new run commit was reported complete'
fi

run_wrapper commit-repo || fail 'wrapper running on the base branch must exit 0'
grep -Fq -- '--summary run-project completed for widget' "$MESH_LOG" \
  || fail 'a passing run that commits directly on its base branch must be reported complete'

TEMP_REPO="$FIX/repos/demo-temporary"
write_prd repos/demo-temporary feature/temporary main
run_wrapper create-temp-worktree feature/temporary "$TEMP_REPO" main \
  || fail 'wrapper with a temporary worktree must exit 0'
[[ ! -e "$TEMP_REPO" ]] || fail 'the simulated child must clean up its temporary worktree'
git -C "$REPO" show-ref --verify --quiet refs/heads/feature/temporary \
  || fail 'temporary worktree cleanup must leave its branch commit in the source repository'
grep -Fq -- '--summary run-project completed for widget' "$MESH_LOG" \
  || fail 'a passing run with a committed temporary branch must be reported complete'

if [[ "$failures" -gt 0 ]]; then
  echo "run-project mesh completion evidence test failed ($failures assertions)" >&2
  exit 1
fi

echo 'run-project mesh completion evidence test passed'
