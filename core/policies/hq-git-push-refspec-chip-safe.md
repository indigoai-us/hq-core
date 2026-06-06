---
id: hq-git-push-refspec-chip-safe
title: Use detached-HEAD + push refspec when committing from a worktree with active task chips
scope: global
trigger: committing/pushing to a specific branch from a worktree while task chips may be active, or when another agent could swap the branch mid-stream
when: git && ( commit || push )
on: [PreToolUse]
enforcement: hard
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

When committing to a specific branch from a worktree that may be hijacked by spawned-task chips, use detached-HEAD + push refspec in a single bash invocation:

```bash
git checkout --detach origin/{target} && {edits or cherry-pick} && git push origin HEAD:{target}
```

NEVER rely on the normal `git checkout {branch} && git commit && git push origin {branch}` flow when chips are active. The chip-management layer can swap the branch back mid-stream, silently landing the commit on the wrong branch and turning the subsequent push into a no-op (because `HEAD` now points at whatever branch the chip restored).

The detached-HEAD form pins the commit to a specific SHA (not a branch ref), and `git push origin HEAD:{target}` forwards the SHA directly to the remote branch — neither step depends on the local branch pointer surviving concurrent mutation.

## Rationale

Task chips (spawned via the Task tool) that touch git can check out branches in the same worktree the parent agent is using. Each chip's checkout is invisible to the parent until the operation completes. When two agents interleave git operations, the sequence:

1. Parent `git checkout main`
2. Chip `git checkout feature-x` (now HEAD → feature-x)
3. Parent `git commit` (lands on feature-x, not main)
4. Parent `git push origin main` (pushes whatever main already was — no-op)

…produces silent data loss. The commit exists locally on feature-x with no upstream tracking, the push reports success, and the "merged" branch on origin is unchanged. Detached-HEAD mode detaches the commit from any branch pointer, and the explicit `HEAD:{target}` refspec forces the push to use the SHA we just created, regardless of what the local branch pointer has become. This also composes safely with `isolation: "worktree"` chips (see `hq-task-chip-worktree-isolation.md`) — if isolation fails or isn't used, detached-HEAD is the last-line safety net.
