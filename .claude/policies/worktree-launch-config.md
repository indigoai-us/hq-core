---
id: worktree-launch-config
title: "Git worktree launch.json + env file gotcha"
scope: global
trigger: "preview_start in worktree returns errors"
enforcement: soft
version: 1
created: 2026-03-12
updated: 2026-03-12
public: true
---

## Rule

When using git worktrees for project execution:

1. `.claude/launch.json` dev server configs reference the original repo path as `cwd`. A worktree lives at a different path (e.g. `repos/private/{company}-{your-project}-wt-feature-...`). Update `launch.json` `cwd` to the worktree path before starting the dev server.
2. Revert `launch.json` `cwd` back to the main repo path after merging the worktree back.
3. Worktrees do NOT inherit `.env.local` from the main repo. Copy `.env.local` from the main repo root into the worktree root before starting the dev server.

## Rationale

Git worktrees check out a branch into a separate directory. The `.claude/launch.json` file stores absolute paths — so any `cwd` pointing at the main repo silently launches the wrong code (or fails if the path is branch-specific). Similarly, `.env.local` is gitignored and not shared, so a fresh worktree directory has no local environment — the dev server starts with missing credentials and fails at runtime rather than at startup.

## Examples

**Correct:**
- Before `preview_start` in a worktree: update `launch.json` cwd to the worktree path, copy `.env.local` from main repo
- After merging worktree: revert `launch.json` cwd back to the main repo path

**Incorrect:**
- Running `preview_start` in a worktree without updating `launch.json` — server starts in the wrong directory
- Starting the dev server in a worktree without `.env.local` — crashes at runtime with missing env var errors
