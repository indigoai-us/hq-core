---
id: hq-git-stash-build-artifacts-conflict
title: git stash pop aborts on build artifact conflicts
scope: global
trigger: using `git stash` to compare typecheck/test/build output before and after changes
enforcement: soft
public: true
version: 1
created: 2026-04-17
updated: 2026-04-17
source: session-learning
---

## Rule

NEVER use `git stash && <command> && git stash pop` to compare tool output before/after changes if the repo has tracked build artifacts (`tsconfig.tsbuildinfo`, `.next/`, `dist/`, lockfile regeneration, etc.). Running the command after stash regenerates the artifact, and `git stash pop` aborts with merge conflict on that artifact — your original changes stay stashed but the workspace is now inconsistent.

ALWAYS either:
- Commit the changes first, then run the command, then compare against HEAD~1
- Explicitly `git checkout -- {artifact_path}` before `git stash pop` to reset the regenerated file
- Or use `git worktree add` for a clean parallel checkout if the comparison is non-trivial

