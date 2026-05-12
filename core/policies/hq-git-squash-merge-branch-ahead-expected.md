---
id: hq-git-squash-merge-branch-ahead-expected
title: After squash-merge, feature branch shows N ahead of origin/main — expected
scope: global
trigger: Observing that a local feature branch reports "N commits ahead of origin/main" after its PR was squash-merged on the remote
enforcement: soft
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: session-learning
---

## Rule

ALWAYS: After a squash-merge completes on GitHub (or any remote that squashes), treat a local feature branch reporting "N commits ahead of origin/main" as expected — NOT as a sync problem that needs rebasing, resetting, or force-pushing.

A squash-merge collapses the branch's N individual commits into a single new commit on `main` with a new SHA. None of the branch's commit SHAs match that new commit. Therefore:

- `git log origin/main..<feature-branch>` still shows all N original commits
- `git status` says the branch is N ahead
- `git merge-base` does not recognize the squash commit as the branch's tip

Correct response after squash-merge:

```bash
# On the feature branch
git checkout main
git pull --ff-only origin main     # pick up the squash commit
git branch -D <feature-branch>     # delete the now-redundant local branch
git remote prune origin            # clean up the tracking ref if GitHub auto-deleted it
```

NEVER: `git rebase origin/main` the post-squash feature branch, `git reset --hard` it, or force-push it "to sync." Each of these either duplicates work that already shipped or rewrites history that no longer needs to exist.

## Rationale

Observed 2026-04-22 after a contributor merged `indigoai-us/hq` PR #90 (hq-core-split) via squash: the local `hq-core-split` branch still reported "13 ahead / 0 behind origin/main" even though `main` now contained the single squash commit with all the changes. The squash-merge workflow inherently produces this apparent divergence because the squash commit on `main` is a brand-new object with no ancestry relationship to any of the branch's original commits.

The safe cleanup is to delete the feature branch rather than try to reconcile histories — the branch has served its purpose (the PR) and the squash commit is already a complete, linear representation of the work on `main`. Attempts to rebase or merge-in the squashed branch either duplicate commits or create noisy merges.

## Related

- `.claude/policies/hq-git-branch-delete-reverify-current.md` — verify before `git branch -D`
- `.claude/policies/hq-git-merge-ff-only-trunk.md` — fast-forward pull on trunk after merge
- `.claude/policies/hq-swarm-pr-branch.md` — swarm-mode branch cleanup pattern
