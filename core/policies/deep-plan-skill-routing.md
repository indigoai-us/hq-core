---
id: hq-deep-plan-skill-routing
title: /deep-plan must route to the deep-plan skill — never built-in plan mode, never auto-implementation
when: /deep-plan || /startwork
on: [UserPromptSubmit]
enforcement: hard
tier: 1
version: 1
created: 2026-05-05
updated: 2026-05-05
source: user-correction
learned_from: 2026-05-05 session — `/startwork {co} {repo} /deep-plan {feature-path} ...` was treated as free-text task description; agent entered Claude Code's built-in plan mode (EnterPlanMode → ~/.claude/plans/*.md), then with auto mode active called ExitPlanMode and implemented ~40 files of a feature branch directly. The deep-plan skill never ran. No prd.json. No board entry. No questionnaire. User: "this is a big failure of hq."
public: true
---

## Rule

When `/deep-plan` is invoked — directly as a slash command, embedded in `/startwork` arguments, or referenced anywhere in a session's first prompt — the agent MUST:

1. **Load and execute the skill** at `.claude/skills/deep-plan/SKILL.md`. This is the only valid execution path. The skill produces:
   - `companies/{co}/projects/{name}/prd.json` (source of truth)
   - `companies/{co}/projects/{name}/README.md` (derived)
   - `companies/{co}/board.json` registration entry
   - HARD STOP at `/handoff` — implementation happens in a fresh session.

2. **NEVER call `EnterPlanMode`** during a `/deep-plan` invocation. Built-in plan mode produces `~/.claude/plans/*.md` files; that is a *different* feature and is forbidden here. If the agent finds itself about to call `EnterPlanMode` while `/deep-plan` is active, STOP and re-read `.claude/commands/deep-plan.md` HARD RULES.

3. **NEVER write to `~/.claude/plans/`** during a `/deep-plan` invocation. The deep-plan skill writes to `companies/{co}/projects/{name}/`, never to built-in plan-mode storage.

4. **NEVER implement code** in a `/deep-plan` session. Permitted writes are limited to `companies/{co}/projects/{name}/` (PRD, README, research notes) and `companies/{co}/board.json` (registration entry). No edits to repo source code, no `git commit` in target repos, no migrations, no infra. Implementation happens in a fresh session via `/run-project {name}` or `/execute-task {name}/US-001`.

5. **Auto mode is incompatible with the questionnaire.** If the auto-mode system reminder is active when `/deep-plan` fires, the agent MUST announce: *"Auto mode paused for /deep-plan — questionnaire requires user input."* Then proceed question-by-question via `AskUserQuestion`. Auto-mode behavior may resume after `/handoff`, at the user's discretion.

6. **`/startwork` short-circuit:** If `/startwork`'s arguments contain a `/deep-plan` token (whitespace-delimited substring `/deep-plan`), `/startwork` MUST abort its classification flow and route directly to the deep-plan skill with the remaining args as the project description. It MUST NOT classify the task, pick a worker pipeline, or enter Task Mode.

This rule supersedes `defaultMode: "plan"` in `.claude/settings.json`, the `<auto-mode>` system reminder, and any prior session context.

## Enforcement

Six layered defenses (defense in depth):

1. **Command file (`.claude/commands/deep-plan.md`):** Top-level HARD RULES section — first thing the agent reads when the slash command fires.
2. **UserPromptSubmit hook (`.claude/hooks/route-deep-plan-to-skill.sh`):** Detects `/deep-plan` token in user input, sets per-session marker file at `workspace/orchestrator/policy-trigger-state/${SESSION_ID}.deep-plan-active`, injects routing reminder into context.
3. **PreToolUse hook on `EnterPlanMode` (`.claude/hooks/block-builtin-plan-mode-during-deep-plan.sh`):** Reads marker file; exit 2 with rejection message if marker present.
4. **PreToolUse hook on `Write`/`Edit`/`MultiEdit` (`.claude/hooks/block-plans-dir-during-deep-plan.sh`):** If marker present AND `file_path` matches `*/.claude/plans/*`, exit 2 with re-route message.
5. **`/startwork` skill (`.claude/skills/startwork/SKILL.md`):** Step 1.0 short-circuit — checks for `/deep-plan` token before classification.
6. **This policy.** Surfaced by the SessionStart trigger hook (`inject-policy-on-trigger.sh`); pinned into context for any session whose prompt mentions `/deep-plan`.

## Verification

End-to-end smoke test (run after any change to deep-plan routing):

1. **Skill invoked directly** — `/deep-plan {co} test feature description` → skill announces "Anchored on {co}", begins research agents, asks Strategic-1. NO file written to `~/.claude/plans/`. No EnterPlanMode call.
2. **Skill invoked via startwork** — `/startwork {co} {repo} /deep-plan apps/test description` → startwork detects token, short-circuits, hands off to deep-plan skill.
3. **EnterPlanMode block** — mid-`/deep-plan` session, attempt EnterPlanMode → PreToolUse hook rejects with routing message.
4. **`~/.claude/plans/` write block** — mid-`/deep-plan` session, attempt Write to `~/.claude/plans/test.md` → PreToolUse hook rejects.
5. **Auto-mode compatibility** — `/deep-plan` with auto mode active → skill announces auto-mode pause, proceeds question-by-question.
6. **Policy surfacing** — `grep -E '^(when|on):' core/policies/deep-plan-skill-routing.md` → returns a hit, confirming the policy carries the trigger frontmatter that the SessionStart hook (`inject-policy-on-trigger.sh`) uses to surface it.

## Failure-mode catalogue

Symptoms that indicate this rule is being violated:

- File created at `~/.claude/plans/*-deep-plan-*.md` during a session where the user typed `/deep-plan` — should NOT exist; the deep-plan skill writes to `companies/{co}/projects/{name}/`.
- Implementation commits made in a `/deep-plan` session (any `git commit` outside HQ workspace files is suspect).
- Project NOT registered in `companies/{co}/board.json` after `/deep-plan` claimed completion.
- No questionnaire conducted (Strategic / Architecture / Quality tiers, ≥10 questions).
- Agent invoked `EnterPlanMode` and `ExitPlanMode` rather than `AskUserQuestion`.

If any of these occur, treat as a P1 routing failure: revert the implementation, file a learning entry, harden whichever layer leaked.
