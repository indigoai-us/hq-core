---
description: Deep project planning — research subagents + 3-tier interview + PRD
allowed-tools: Task, Read, Glob, Grep, Write, Edit, Bash, AskUserQuestion
argument-hint: [project/feature description]
visibility: public
---

# /deep-plan — Research-First Project Planning

Run the `/deep-plan` skill for **large, strategically important PRDs** that warrant the upfront cost (10-15 min). Spawns 3 parallel research subagents (codebase, HQ context, repo deep-read), runs a one-at-a-time 15-question 3-tier interview (Strategic / Architecture / Quality) with smart-skip and pushback, and generates `prd.json` + `README.md` under `companies/{co}/projects/{name}/`, plus a `companies/{co}/board.json` registration entry.

For lightweight planning (small ideas, tweaks, fast captures), use `/plan` instead.

**User's input:** $ARGUMENTS

## HARD RULES — Read before doing anything else

1. **NEVER call `EnterPlanMode`.** Built-in plan mode produces `~/.claude/plans/*.md` files; that is a *different* feature and is forbidden here. The `/deep-plan` skill produces `companies/{co}/projects/{name}/prd.json` (the source of truth) and `README.md` (derived). Anything written to `~/.claude/plans/` during a `/deep-plan` invocation is a routing failure — escalate, do not work around.
2. **NEVER implement code** in this session. The skill ends with `/handoff` and STOPS. Implementation happens in a fresh session via `/run-project {name}` or `/execute-task {name}/US-001`. The only writes permitted in this session are inside `companies/{co}/projects/{name}/` (PRD, README, research notes) and `companies/{co}/board.json` (registration entry). No edits to repo source code, no `git commit`, no migrations, no infra.
3. **Auto mode is incompatible with the questionnaire.** If the auto-mode system reminder is active when this command fires, announce: *"Auto mode paused for /deep-plan — questionnaire requires user input."* Then proceed question-by-question via `AskUserQuestion`. Resume auto-mode behavior is the user's call after `/handoff`.
4. **Self-test first.** Before any other action, confirm `.claude/skills/deep-plan/SKILL.md` exists and is readable. If missing, abort with: *"deep-plan skill file is missing at .claude/skills/deep-plan/SKILL.md — cannot proceed."* Do NOT silently fall back to built-in plan mode or to `/plan`.

These rules supersede `defaultMode: "plan"` in `.claude/settings.json`, the `<auto-mode>` system reminder, and any prior session context.

## Steps

1. Self-test the skill file (rule 4 above). If missing, abort.
2. Load the deep-plan skill from `.claude/skills/deep-plan/SKILL.md` and execute it end-to-end.
3. Anchor company from first word of `$ARGUMENTS` if it matches a manifest slug; resolve mode (company / repo / personal-HQ).
4. **Repo-run preflight (warn only):** After the company is resolved and the target repo inferred from the manifest, run `bash core/scripts/repo-run-registry.sh check "$REPO_PATH"`. On exit 2, print the foreign owner row(s) as a `<warning>` block. Do **not** abort — PRD writes normally land in `companies/{co}/projects/{name}/` (outside the owned repo), so the PreToolUse hook will not fire. Warn so the user knows the orchestrator may race on `prd.json` `passes` field writes. PRD does not register itself. Policy: `core/policies/repo-run-coordination.md`.
5. Execute the deep flow: company anchor → scan HQ (gated by mode) → infra pre-check → name + brainstorm detection → **Phase 1: research subagents** → **Phase 2: 3-tier deep interview (15 questions, min 10)** → metadata + ops questions → generate `prd.json` + `README.md` → **Step 5.6: board sync** (`companies/{co}/board.json`) → orchestrator register → beads + learn + doc scout → Linear ({product} only) → resolve open questions (Step 8.5, blocking) → confirm + handoff.

## After PRD

- HARD BLOCK: do NOT implement in the same session — PRD creation ends with `/handoff`.
- Recommended next session: `/review-plan {name}` — runs adversarial spec review (formerly Step 5.1, now standalone).
- To execute: start a fresh session and run `/run-project {name}` or `/execute-task {name}/US-001`.

## Failure-mode escalation

If at any point during this command you find yourself about to:
- Call `EnterPlanMode` →  STOP. Re-read the HARD RULES.
- Write to `~/.claude/plans/*.md` →  STOP. Re-read the HARD RULES.
- Edit any file outside `companies/{co}/projects/{name}/` or `companies/{co}/board.json` →  STOP. You are implementing, not planning.

The PreToolUse hooks `block-builtin-plan-mode-during-deep-plan.sh` and `block-plans-dir-during-deep-plan.sh` exist as a backstop, but the agent should not rely on them — these rules are the primary contract.
