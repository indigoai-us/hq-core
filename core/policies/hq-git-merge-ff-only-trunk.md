---
id: hq-git-merge-ff-only-trunk
title: Use git merge --ff-only for branch-to-trunk merges
when: git && merge
on: [AssistantIntent, PreToolUse]
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

ALWAYS use `git merge --ff-only` when merging a feature branch into a trunk (main, master, release/*) from the command line. `--ff-only` fails loudly on divergence instead of silently creating a merge commit with unintended content.

Correct workflow:

```bash
# On feature branch, ensure it's rebased onto current trunk
git fetch origin
git rebase origin/main

# Switch to trunk and fast-forward
git checkout main
git pull --ff-only              # pull in any new trunk commits
git merge --ff-only feature-xyz # fails if feature-xyz doesn't fast-forward cleanly
git push origin main
```

If `git merge --ff-only` fails with `Not possible to fast-forward, aborting.`:

1. The trunk advanced while you were offline (automated commits from CI, other sessions landing PRs, etc.)
2. Resolve by: `git checkout feature-xyz && git rebase origin/main` to replay your commits onto the fresh trunk
3. Re-run the ff-only merge

Never use plain `git merge feature-xyz` on trunk. Plain merge succeeds in both fast-forward and non-fast-forward cases — the non-FF path silently creates a merge commit that bundles both your branch AND whatever landed on origin while you were offline. The merge commit's author becomes you, obscuring which commits actually came from your PR vs ambient trunk updates.

`gh pr merge --rebase` and `gh pr merge --squash` bypass this concern entirely because they operate server-side on a known base; the rule applies specifically to local CLI merges.

## Rationale

Automated systems landing commits on origin/main (scheduled tasks, other sessions, CI auto-merges) create silent divergence. A session that checked out main at 10:00 and merges at 14:00 may find origin/main has advanced several commits in the interim. Plain `git merge` creates a merge commit without any warning — the operator sees the merge succeed and pushes, inadvertently attributing ambient trunk updates to their PR in the git history.

`--ff-only` converts this from a silent attribution bug into a loud failure. The fix (rebase branch onto fresh trunk) is straightforward and preserves clean linear history. The safety property is worth the extra step.

Composes with `hq-git-divergence-check-both-directions.md` (symmetric ahead/behind inspection before acting) and `hq-pull-before-work.md` (always fetch/pull before starting).
