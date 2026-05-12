---
id: hq-git-branch-delete-reverify-current
title: Re-verify current branch before git branch -D in repos with worktrees
scope: global
trigger: Before `git branch -D <branch>` or `git branch -d <branch>` in any repo that has active git worktrees
enforcement: soft
public: true
version: 1
created: 2026-04-19
updated: 2026-04-19
source: session-learning
---

## Rule

Before running `git branch -D <branch>` (or `-d`) in a repo with worktrees, re-run `git branch --show-current` in the target working tree immediately before the delete — even if you checked earlier in the same session. Git refuses to delete a branch that any worktree has checked out (`error: Cannot delete branch 'X' checked out at 'path'`), and the branch state can shift between your initial check and the delete (another sub-agent switched branches, a `run-project` worktree re-checked out, a script moved HEAD).

Safe sequence:

```bash
cd <target-worktree-or-repo>
current=$(git branch --show-current)
if [ "$current" = "<branch-to-delete>" ]; then
  # Move off the branch first — pick a safe neutral branch
  git checkout main   # or: git checkout <other>
fi
git branch -D <branch-to-delete>
```

For cross-worktree cleanup:

```bash
# Confirm no worktree still has the branch checked out
git worktree list | grep "<branch-to-delete>" && \
  echo "Worktree still holds branch — switch it off first" && exit 1
git branch -D <branch-to-delete>
```

Composes with `run-project-dry-run-branch-leak.md` (which recommends `git branch -d` after dry runs — this rule adds the re-verify step to that cleanup).

## Rationale

Observed 2026-04-19 while cleaning up a release branch. `git branch --show-current` reported `main` earlier in the session, so the subsequent `git branch -D release/v11.1.1` was expected to succeed. Between the two checks, a separate `run-project` worktree had checked out `release/v11.1.1` for its own work. `git branch -D` failed with `Cannot delete branch 'release/v11.1.1' checked out at ...`. The failure was safe (git's refusal is the correct behavior), but the session had to re-orient to discover which worktree held the branch and whether it was safe to move it.

Re-verifying `git branch --show-current` immediately before the delete is ~free (single git call) and catches both of: (a) session drift since the initial check, (b) cross-worktree ownership. Always pay the tiny verification cost rather than let the delete attempt fail.

Related: `hq-git-discipline.md` rule 1 (verify branch before committing). Same principle applied to the delete side of branch operations.
