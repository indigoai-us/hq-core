---
id: post-edit-verification
title: Universal Post-Edit Verification
scope: global
trigger: after completing file edits in any repo with a configured typecheck/lint
enforcement: soft
version: 1
created: 2026-03-31
source: brainstorm-session
public: true
---

## Rule

After completing edits in a repo that has typecheck or lint configured, run the project's verification commands before reporting the task as done:

1. Check if the repo has a typecheck command (tsconfig.json → `tsc --noEmit`, package.json `check` script, etc.)
2. Check if the repo has a lint command (eslint, oxlint, biome, ruff, etc.)
3. Run both. If either fails, fix the errors before reporting completion.

For repos with PR-hook-enforced checks (e.g. `bun check && bun lint`), extend the same checks to mid-task verification.
For other repos: detect from package.json scripts or config files.

If no typecheck or lint is configured, state that explicitly rather than silently skipping.

## Rationale

File writes succeed even when the resulting code doesn't compile. Without post-edit verification, tasks are reported complete with broken type errors or lint violations that compound across subsequent edits. Catching errors immediately after the edit — not just at PR time — prevents wasted context on cascading fixes.
