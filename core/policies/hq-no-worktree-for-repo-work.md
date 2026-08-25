---
id: hq-no-worktree-for-repo-work
title: "Never create HQ worktrees or branches for repo work"
when: /startwork || repo || worktree
on: [UserPromptSubmit, SessionStart]
enforcement: hard
tier: 1
version: 3
created: 2026-04-03
updated: 2026-08-22
source: user-correction
public: true
---

## Rule

NEVER create a git worktree or new branch in HQ when starting work on a project repo. HQ must stay on `main` at all times. All branching and worktree creation happens inside the target repo itself. Each repo has its own branching strategy independent of HQ.

When `/startwork` resolves to a repo context, `cd` into that repo and work there directly. Do not use `EnterWorktree` on the HQ repository.

## Rationale

Creating worktrees in HQ causes: (1) unnecessary HQ branches that diverge from main, (2) git status showing massive deletes of unrelated HQ files, (3) confusion about which directory is canonical, (4) wasted session time cleaning up. HQ is an orchestration layer — it doesn't need branches for repo work.

## Mechanical enforcement

`.claude/hooks/block-hq-worktree-session.sh` is the mechanical backstop for the
half of this rule that a model cannot un-do once it has happened: a Claude
session that is already *running* HQ from a linked worktree. It fires on
SessionStart (banner), UserPromptSubmit (exit 2 — the prompt is erased) and
PreToolUse (exit 2 — every tool call is refused), so an ordinary session
started from an HQ worktree can do no work at all.

Task subagents launched from the canonical HQ checkout with
`isolation: "worktree"` are intentionally exempt. Claude identifies hook calls
inside those delegated children with a non-empty `agent_id`; manually started
worktree sessions do not receive that field and remain blocked. `agent_type`
alone is not an exemption because manually started `--agent` sessions have it.

Outside that delegated-task exemption, it blocks exactly two shapes:

1. the session's project directory (`CLAUDE_PROJECT_DIR`) is itself a linked
   git worktree; or
2. the session's working directory is a linked worktree whose main worktree is
   the HQ root — that is, a worktree cut from the HQ repository.

Worktrees of source repos under `repos/` are explicitly unaffected. Editing a
checkout from `workspace/worktrees/<repo>/<name>/` is the normal, required flow
(`block-core-writes-bash.sh` demands it); those worktrees resolve to the repo
checkout as their main worktree, never to the HQ root, so the guard never fires
on them.

Escape hatch for a session that genuinely must run this way:
`HQ_ALLOW_HQ_WORKTREE=1`. Regression coverage:
`core/scripts/tests/block-hq-worktree-session.test.sh`.
