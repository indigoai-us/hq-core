---
id: git-checkout-not-a-probe
title: Never use `git checkout {branch} -- .` to inspect another branch's state
scope: global
trigger: git checkout, git probe, branch comparison
enforcement: hard
tier: 1
public: true
---

## Rule

`git checkout {branch} -- .` is NOT a read-only probe. It **overwrites your current working tree** with every file from `{branch}`, leaving HEAD pointing at your original branch. The result is a staged undo of every uncommitted and committed-but-not-yet-pushed change that differs between the two branches — impossible to tell from the commit graph alone.

When you want to inspect another branch without switching:

```bash
# Show a single file from another branch without touching working tree
git show main:path/to/file

# Diff current branch against main without modifying anything
git diff main..HEAD -- path/to/file

# Compare lint/build output between branches (proper branch switch)
git stash -u
git switch main
npm run lint
git switch -
git stash pop

# List files that differ
git diff --name-only main..HEAD
```

When you need full-tree content from another branch in a scratch space, use a worktree:

```bash
git worktree add /tmp/main-check main
# ... inspect /tmp/main-check ...
git worktree remove /tmp/main-check
```

## Recovery if accidentally run

1. `git rev-parse HEAD` — verify HEAD still points at the right commit
2. `git rev-parse origin/{branch}` — verify the branch pointer on origin is intact
3. If HEAD and origin match (commits safe), `git reset --hard HEAD` restores the working tree cleanly
4. If local has unpushed commits past origin, use `git reset --hard HEAD` **only after** confirming those commits are still in `git reflog` — they should be, because `checkout -- .` doesn't touch commits, only the working tree

## Rationale

Every US-01 through US-09 file became "M" in `git status` — an accidental full-sprint undo at the working-tree level.

Fortunately the commits were already pushed to origin, so `git reset --hard HEAD` recovered cleanly. Had the commits been local-only, a `git reflog` rescue would have been needed. Had the author panicked and re-staged + committed the "changes," the sprint would have been genuinely destroyed.

The confusion: `git checkout {branch}` (switch branch) and `git checkout {branch} -- path` (restore specific paths from branch) are documented as the same command but do fundamentally different things. The path form is a write operation dressed up as a read.

When you catch yourself typing `git checkout {something} -- .`, STOP. The `--` pathspec form with `.` means "overwrite everything in the working tree from that ref." It is never the right way to inspect.
