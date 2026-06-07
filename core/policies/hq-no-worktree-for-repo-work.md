---
id: hq-no-worktree-for-repo-work
title: "Never create HQ worktrees or branches for repo work"
scope: global
trigger: "/startwork, repo-scoped tasks, company repo work"
when: /startwork || repo || worktree
on: [UserPromptSubmit, SessionStart]
enforcement: hard
tier: 1
version: 1
created: 2026-04-03
updated: 2026-04-03
source: user-correction
public: true
---

## Rule

NEVER create a git worktree or new branch in HQ when starting work on a project repo. HQ must stay on `main` at all times. All branching and worktree creation happens inside the target repo itself. Each repo has its own branching strategy independent of HQ.

When `/startwork` resolves to a repo context, `cd` into that repo and work there directly. Do not use `EnterWorktree` on the HQ repository.

## Rationale

Creating worktrees in HQ causes: (1) unnecessary HQ branches that diverge from main, (2) git status showing massive deletes of unrelated HQ files, (3) confusion about which directory is canonical, (4) wasted session time cleaning up. HQ is an orchestration layer — it doesn't need branches for repo work.
