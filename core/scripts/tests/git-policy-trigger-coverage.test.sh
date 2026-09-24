#!/usr/bin/env bash
# git-policy-trigger-coverage.test.sh — pins the trigger coverage of two hard
# policies whose `when:` expressions were narrowed to stop firing on read-only
# git commands:
#
#   core/policies/hq-github.md
#     must fire on every repository-scoped gh family (the rule is "always pass
#     an explicit repo to gh"), and on git commands that talk to a remote.
#   .claude/policies/hq-core-staging-changes-via-new-worktrees.md
#     must fire on every git command that moves HEAD, rewrites the working tree
#     or index, or updates refs, because any of them run in the primary checkout
#     changes files beneath concurrent workers.
#
# Both must stay quiet on read-only commands (git status/log/diff/show), which
# was the point of narrowing them.
#
# Each case derives facts with the production deriver
# (core/scripts/derive-trigger-facts.sh) and evaluates the policy's current
# `when:` with the production evaluator (core/scripts/eval-trigger.sh), so the
# test follows the frontmatter rather than a copy of the expression.
#
# Explicitly wired into .github/workflows/pr-checks.yml — tests here are NOT
# auto-discovered.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DERIVE="$ROOT/core/scripts/derive-trigger-facts.sh"
EVAL="$ROOT/core/scripts/eval-trigger.sh"
PASS=0; FAIL=0

when_of() {
  awk '/^---$/{d++; next} d==1 && /^when:/{sub(/^when:[[:space:]]*/, ""); print; exit}' "$1"
}

GITHUB_POLICY="$ROOT/core/policies/hq-github.md"
WORKTREE_POLICY="$ROOT/.claude/policies/hq-core-staging-changes-via-new-worktrees.md"
GITHUB_WHEN="$(when_of "$GITHUB_POLICY")"
WORKTREE_WHEN="$(when_of "$WORKTREE_POLICY")"
[ -n "$GITHUB_WHEN" ] || { echo "FAIL: no when: in $GITHUB_POLICY"; exit 1; }
[ -n "$WORKTREE_WHEN" ] || { echo "FAIL: no when: in $WORKTREE_POLICY"; exit 1; }

# fires <when-expr> <bash-command> -> exit 0 when the PreToolUse Bash payload
# for the command satisfies the expression
fires() {
  local facts
  facts="$(jq -cn --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}' \
    | HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$DERIVE" PreToolUse 2>/dev/null | head -1)"
  bash "$EVAL" "$1" "$facts" >/dev/null 2>&1
}

expect() { # <label> <fire|quiet> <when-expr> <command>
  local got=quiet
  fires "$3" "$4" && got=fire
  if [ "$got" = "$2" ]; then
    PASS=$((PASS+1)); echo "ok   [$1] $2: $4"
  else
    FAIL=$((FAIL+1)); echo "FAIL [$1] expected $2, got $got: $4"
  fi
}

echo "== hq-github =="
for c in \
  "gh pr merge 12 --squash" \
  "gh run rerun 123" \
  "gh issue create --title x" \
  "gh release create v1" \
  "gh workflow run ci.yml" \
  "gh api repos/o/r/pulls" \
  "gh label delete obsolete --yes" \
  "gh repo edit --visibility private" \
  "gh secret set FOO" \
  "gh variable set BAR" \
  "gh ruleset list" \
  "gh cache delete --all" \
  "git push origin main" \
  "git fetch origin" \
  "git remote add upstream https://example.invalid/r.git"; do
  expect hq-github fire "$GITHUB_WHEN" "$c"
done
for c in "git status" "git log --oneline -5" "git diff HEAD~1" "ls -la"; do
  expect hq-github quiet "$GITHUB_WHEN" "$c"
done

echo "== hq-core-staging-changes-via-new-worktrees =="
for c in \
  "git worktree add ../w" \
  "git branch -D old" \
  "git commit -m x" \
  "git push origin HEAD" \
  "git fetch origin main" \
  "git pull" \
  "git switch -c feature" \
  "git checkout feature" \
  "git -C /abs/repo checkout main" \
  "git merge origin/main" \
  "git rebase origin/main" \
  "git reset --hard HEAD~1" \
  "git stash push -m x" \
  "git restore ." \
  "git cherry-pick abc123" \
  "git revert abc123" \
  "git am fix.patch" \
  "git apply fix.patch" \
  "git add -A" \
  "git rm old.txt" \
  "git mv a b" \
  "git clean -fd" \
  "git tag v1" \
  "gh pr create --fill"; do
  expect worktree fire "$WORKTREE_WHEN" "$c"
done
for c in "git status" "git log --oneline -5" "git diff HEAD~1" "git show HEAD" "git rev-parse HEAD" "ls -la"; do
  expect worktree quiet "$WORKTREE_WHEN" "$c"
done

echo "git-policy-trigger-coverage: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
