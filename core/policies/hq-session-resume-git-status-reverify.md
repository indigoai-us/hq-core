---
id: hq-session-resume-git-status-reverify
title: Re-run `git status` fresh before acting on session-resume dirty-state reports
when: git && checkout
on: [AssistantIntent, PreToolUse]
enforcement: soft
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: session-learning
---

## Rule

NEVER trust `git status` output embedded in a session-resume system-reminder as authoritative. The snapshot may pre-date post-commit formatter mutations (prettier, lint-staged, husky hooks, pre-push reformatters) and show files as modified that are actually already committed on the current HEAD.

Before taking any action that depends on the dirty-state picture — in particular stash, checkout, reset, worktree move, `git restore`, or "am I about to lose work?" triage — re-run `git status` live:

```bash
git -C "$REPO" status --porcelain
```

Compare the live output to the system-reminder snapshot. If they differ, treat the live output as ground truth.

Harmless if wrong in the "phantom dirty" direction (a `git stash` on a clean tree is a no-op and prints `No local changes to save`). Not harmless in the "phantom clean" direction — if the snapshot misses real new dirty edits, you could skip a stash you needed. Either way, the 10ms re-run removes the ambiguity.

## Rationale

System-reminder snapshots are captured at session-start and persist through the turn. Any post-snapshot process (formatter, commit hook, amended commit, external editor save) can change the working tree without the snapshot updating. Downstream logic that reads "Modified: foo.ts" from the snapshot and then stashes or checks out may be acting on obsolete information.

Observed during handoff recovery: snapshot listed M on files that `git diff HEAD` confirmed were already part of the HEAD commit, leading to a spurious "do I stash this?" cycle. Re-running `git status` live showed a clean tree — the snapshot was simply stale.
