---
id: run-project-worktree-heal-orphan
title: run-project.sh must heal orphan worktree directories before create
scope: command
trigger: /run-project, run-project.sh ensure_worktree, git worktree add
enforcement: hard
version: 1
created: 2026-04-16
updated: 2026-04-16
source: back-pressure-failure
command: run-project
---

## Rule

`ensure_worktree` in `scripts/run-project.sh` must detect and heal orphan directories at the target worktree path BEFORE calling `git worktree add`. `git worktree add` refuses to create a worktree when the target path already exists, even an empty directory — so a partially-completed earlier run (e.g. dry-run that ran `bun install` but died before `git worktree add` succeeded) leaves a directory of regenerable artifacts that permanently blocks subsequent runs until manually cleaned.

Healing steps (in order):
1. `git worktree prune` on the source repo to drop stale metadata
2. If `$wt_path/.git` still exists after prune → ABORT with clear remediation hint (do not force-remove a live worktree)
3. If `$wt_path` contents are limited to regenerable artifacts (`node_modules`, `.expo`, `.next`, `.turbo`, `dist`, `build`, `.DS_Store`) → `rm -rf "$wt_path"` and proceed with create
4. If `$wt_path` contains ANY other files → ABORT with clear remediation hint (never destroy possible user work)

