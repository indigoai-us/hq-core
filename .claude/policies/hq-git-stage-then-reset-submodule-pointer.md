---
id: hq-git-stage-then-reset-submodule-pointer
title: Use git add -A then reset to un-stage an unwanted submodule pointer bump
scope: global
trigger: Staging a worktree that contains both wanted changes AND a dirty submodule whose pointer should NOT bump in this commit
enforcement: soft
public: true
version: 1
created: 2026-04-25
updated: 2026-04-25
source: session-learning
---

## Rule

ALWAYS: When staging a worktree where you want most changes but NOT the submodule pointer bump (e.g. an embedded knowledge `.git` repo whose advancement belongs in a separate commit), use:

```bash
git add -A
git reset HEAD -- <submodule-or-gitlink-path>
```

Do NOT enumerate every wanted path manually. Manual enumeration is error-prone — it's easy to miss a new file, an untracked rename, or a deletion. Surgically un-staging the one unwanted submodule pointer after a wholesale `git add -A` is reliable and visibly auditable in `git status` before commit.

Verify before committing:

```bash
git status --short        # confirm the submodule line is unstaged
git diff --cached --stat  # confirm staged set matches expectation
```

## Rationale

Discovered during a session where the worktree had many small fixes across files PLUS a dirty pattern-1 embedded knowledge submodule (orphan 160000 gitlink) whose pointer should advance in its own commit, not piggyback on the unrelated work. Trying to enumerate every wanted file manually missed two new files; switching to `git add -A` followed by a single targeted `git reset HEAD -- <submodule-path>` produced a clean, visibly correct staged set on the first try. The pattern generalizes to any case where you want a wide stage with one or two surgical exclusions — stage everything, then back out the specific path.
