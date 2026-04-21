---
id: run-project-dry-run-branch-leak
title: run-project.sh --dry-run leaks worktree branches
scope: command
command: run-project
trigger: Running /run-project {slug} --dry-run against a PRD that declares branchName
enforcement: soft
version: 1
created: 2026-04-10
updated: 2026-04-10
---

## Rule

`scripts/run-project.sh --dry-run {slug}` cleans up its ephemeral git worktree when it finishes, but **it does NOT delete the feature branch that was created alongside the worktree**. The branch (named per `prd.json.branchName`) persists in the target repo at whatever HEAD was active during the dry run.

**Consequences:**
- A subsequent real run of the same PRD that does `git checkout -b {branchName}` will fail with `fatal: A branch named '{branchName}' already exists.`
- The US-L01-style "clean working tree" story in a landing PRD will report a stale branch it didn't create and can't explain.
- Over time, abandoned dry-run runs leave dead branches in every repo touched by orchestrator planning.

**Mitigation (after any `--dry-run` invocation):**

```bash
cd repos/{pub|priv}/{repo}
branch=$(jq -r '.branchName' /path/to/prd.json)
git branch -d "$branch" 2>/dev/null || true  # safe: fails if branch has unique commits
```

If the dry-run branch has diverged (shouldn't — dry-run is read-only for the worktree), investigate before force-deleting.

**Fix at source:** Add a trap in `scripts/run-project.sh` dry-run path that runs `git branch -d "$branch"` after the worktree is removed, gated on the branch HEAD matching the checkout point (so real-run branches aren't touched).

## Related

- `.claude/policies/run-project-file-locks-stale.md` — related orchestrator cleanup hygiene
- `scripts/run-project.sh` — dry-run codepath (worktree cleanup but no branch cleanup)
