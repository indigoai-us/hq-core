---
id: hq-swarm-pr-branch
title: Swarm worktree merges land on local main
scope: command
trigger: /run-project --swarm completion, PR creation after swarm execution
enforcement: hard
version: 1
created: 2026-03-11
updated: 2026-03-11
source: success-pattern
---

## Rule

After `run-project --swarm` completes, all story commits are cherry-picked onto local `main` (the working tree), NOT the PRD's `branchName`. To create a PR:

1. Delete the stale feature branch (`git branch -D {branchName}`)
2. Create a new branch from local main (`git checkout -b {branchName}`)
3. Push with force (`git push -u origin {branchName} --force`)

The PRD `branchName` is only used for per-story worktree naming during swarm execution, not as the merge target.

