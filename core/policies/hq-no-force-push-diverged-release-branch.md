---
id: hq-no-force-push-diverged-release-branch
title: Never force-push a release branch with diverged origin history
when: git && push
on: [PreToolUse]
enforcement: hard
tier: 1
public: true
version: 2
created: 2026-04-18
updated: 2026-04-29
source: session-learning
---

## Rule

NEVER force-push a release branch (e.g. `release/v11.x.x`), `main`, `master`, or any production branch when `git fetch` shows origin has commits you don't have locally.

Safe procedure when origin has diverged:

1. `git fetch` — confirm divergence (count commits ahead/behind)
2. `git stash push -m "drift-recoverable-{timestamp}"` or `git branch drift-{branch}-{timestamp}` to preserve local uncommitted changes
3. `git checkout {branch}` then `git pull --ff-only` or `git reset --hard origin/{branch}` (only after step 2 preserved local work)
4. File the divergence as a separate follow-up task — do NOT overwrite origin history as a shortcut
5. Note the recovery handle (stash ref or backup branch name) in the session thread so a later session can reconcile

Force-push is acceptable only when:

- The target is an owned feature branch (no other collaborators)
- The user has explicitly authorized the force-push for that specific operation
- A separate hard policy grants the exception (e.g. `hq-force-push-pii-scrub-completeness` covers the specific scenario of scrubbing a pre-migration repo's history to remove PII — with tags/releases also force-updated)

This rule composes with, does not replace, `hq-force-push-pii-scrub-completeness`.

## Rationale

Observed 2026-04-18: `origin/release/v11.1.1` had diverged with 6 commits (including `719ac9d fix(v11.1.1)...`) that local didn't have. Force-pushing would have silently erased those commits. Correct recovery: stashed local drift, fast-forwarded main to `94b5410`, flagged v11.1.1 divergence as a v11.3.0 follow-up task.

The general principle: force-push destroys origin history atomically — once done, recovery requires reflog on every collaborator's clone. For release branches (which other workflows depend on), this can cascade through CI, deployments, tags, and external consumers. Stash + follow-up is always the safer sequence.
