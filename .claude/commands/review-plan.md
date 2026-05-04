---
description: Structured plan review with scope modes (EXPANSION / HOLD / REDUCTION) — stress-test plans before execution
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(qmd:*), AskUserQuestion
argument-hint: "[path/to/plan-or-prd]"
visibility: public
---

# Structured Plan Review

Run the `/review-plan` skill to review a plan, PRD, or proposal with configurable rigor.

## Input Resolution

1. If `$ARGUMENTS` contains a file path → review that file
2. If in plan mode → review the current plan file
3. If no args and not in plan mode → review `git diff origin/main` (falls back to `/review` behavior)

## Steps

1. Load the review-plan skill from `.claude/skills/review-plan/SKILL.md`
2. Resolve the input to review (see resolution order above)
3. Execute the review: system audit → Step 0 (scope challenge + mode selection) → 10 review sections → completion summary

## Scope Modes

- **EXPANSION** — push scope up, find the 10x version, identify delight opportunities
- **SELECTIVE EXPANSION** — identify which parts should grow and which should stay tight; expand selectively
- **HOLD** — accept scope, make it bulletproof, catch every failure mode
- **REDUCTION** — cut to minimum viable value, defer everything else
