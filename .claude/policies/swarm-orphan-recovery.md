---
id: hq-cmd-run-project-swarm-orphan-recovery
title: Recover orphaned commits from swarm worktrees
scope: command
trigger: /run-project swarm failure, "passes not set" error despite exit=0
enforcement: soft
version: 1
created: 2026-03-12
updated: 2026-03-12
source: workflow-improvement
---

## Rule

When `run-project.sh` swarm mode reports "passes not set" despite a sub-agent exiting with code 0, do NOT assume the work was lost. The sub-agent's commits may be orphaned in the worktree. Recovery steps:

1. Locate the story's worktree (typically `{repo}/.worktrees/{story-id}/` or a sibling git dir)
2. Check for orphaned commits: `git fsck --unreachable` inside the worktree
3. Inspect all commits across refs: `git log --all --oneline` in the worktree
4. If orphaned commits exist, cherry-pick them onto the feature branch:
   ```bash
   git cherry-pick <commit-sha>
   ```
5. Only after checking worktree history should work be considered lost and re-executed

