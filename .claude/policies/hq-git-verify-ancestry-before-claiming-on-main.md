---
id: hq-git-verify-ancestry-before-claiming-on-main
title: Verify commit ancestry before claiming work is on main; cherry-pick dangling commits from merged-and-deleted PRs
scope: global
trigger: Looking for work that should be on `main` but a feature branch is missing or appears deleted, OR before stating "this commit is on main" in any handoff/report, OR before forming a debugging hypothesis around a suspect commit affecting deployed behavior
enforcement: soft
public: true
version: 2
created: 2026-04-24
updated: 2026-04-28
source: session-learning
---

## Rule

ALWAYS verify a commit's ancestry against `main` before treating it as "merged" or "on main." Use:

```bash
git merge-base --is-ancestor <sha> main && echo "on main" || echo "NOT on main"
```

When a PR was merged via "squash and merge" or "rebase and merge" and the source branch was auto-deleted, the original commits do NOT become ancestors of `main` — only the squashed/rebased replacement does. The originals are now **dangling commits**: still in the local object database, still recoverable via cherry-pick, but invisible to `git branch --contains` and absent from `git log main`.

Recovery procedure when original work appears lost:

```bash
# 1. Confirm the commit still exists in the object DB
git cat-file -t <sha>     # → "commit" if still present
git show <sha>            # inspect the change

# 2. Confirm it's NOT yet on main
git merge-base --is-ancestor <sha> main && echo on || echo off

# 3. Cherry-pick onto current branch
git cherry-pick <sha>
```

Window: dangling commits survive until `git gc` runs (default ~2 weeks via reflog expiry, but can be triggered earlier by `git gc --prune=now` or aggressive housekeeping). Recover promptly — do not assume "the branch is gone, the work is gone."

### Debugging-time corollary: prove deployment before chasing a hypothesis

Before forming or pursuing a hypothesis that a specific commit caused a regression in *deployed* behavior, prove the commit is actually on the deployed branch:

```bash
git fetch origin
git branch -a --contains <sha>     # which refs include this commit
git merge-base --is-ancestor <sha> origin/main && echo "on main" || echo "NOT on main"
```

A suggestive commit message (e.g. one that touches the suspected subsystem) is *not* evidence of deployment. Feature branches that were never merged remain in the object database and surface in `git log` searches but contribute nothing to runtime. Skip the hypothesis until ancestry is confirmed.

## Rationale

Observed 2026-04-24 during a holler-comms migration recovery. A merged PR with auto-deleted source branch left the impression that recent work had vanished — `git log main` did not show the commits, `git branch -a` did not list the branch. The reflexive read was "the branch is missing." `git merge-base --is-ancestor` against the dangling commit SHA confirmed it was NOT on main, but `git cat-file -t` confirmed the object still existed locally. A single `git cherry-pick` recovered the file onto the current working branch.

The deeper principle: branch deletion ≠ commit deletion. Commits live in the object database keyed by SHA; branches are just refs pointing into that database. Deleting a ref orphans its tip commit (and any unmerged ancestors), making them dangling but not destroyed. The recoverable window is bounded by reflog expiry and `git gc`, but during that window cherry-pick is the cleanest recovery path.

Composes with `hq-git-fsck-stash-recovery.md` (which uses `git fsck --dangling` to enumerate orphans when SHA is unknown). When the SHA is known, skip fsck and go straight to `merge-base --is-ancestor` + cherry-pick.

The v2 debugging-time corollary covers the inverse failure mode: not "I lost work that was merged" but "I'm investigating a regression and a suspicious-looking commit pulled me down a rabbit hole because I never confirmed it was deployed." Same primitive (`git branch --contains` / `merge-base --is-ancestor`), inverted goal — eliminate non-deployed commits from the suspect list before spending investigation time on them.
