---
id: hq-cross-session-stage-not-commit
title: Cross-Session Handoff Uses Stage-Not-Commit
scope: global
trigger: coordinated work across parallel Claude Code sessions on the same repo
enforcement: soft
public: true
version: 2
created: 2026-04-16
updated: 2026-04-29
source: session-learning
---

## Rule

When a parallel session needs to hand work to a driver session (e.g. policy drafts, staged code edits, bundled-release contributions), the parallel session SHOULD `git add` its changes but NOT commit them. The driver session owns the commit boundary and folds the staged paths into its own in-progress work.

- Parallel session: edit files → `git add <explicit-paths>` → hand off (no `git commit`).
- Driver session: detect staged paths via `git status`, verify scope matches agreed handoff, include them in its next commit (may need additional processing — e.g. Policy Context Stripping for promotion handoffs).
- Never have a parallel session `git commit` when the driver is mid-branch; a stray commit lands on whatever branch happens to be checked out and fragments the release history.

## Rationale

Two sessions committing to the same branch produce interleaved commits, unclear authorship, and easy-to-miss handoff points. Staging instead of committing makes the handoff explicit (`git status` in the driver shows new entries under `Changes to be committed`), preserves atomic release commits, and lets the driver apply any last-mile processing (stripping, scrubbing, regeneration) before the work is frozen in git history.
