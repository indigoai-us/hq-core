---
description: Deep project planning — research subagents + 3-tier interview + PRD
allowed-tools: Task, Read, Glob, Grep, Write, Bash, AskUserQuestion
argument-hint: [project/feature description]
visibility: public
---

# /deep-plan — Research-First Project Planning

Run the `/deep-plan` skill for **large, strategically important PRDs** that warrant the upfront cost (10-15 min). Spawns 3 parallel research subagents (codebase, HQ context, repo deep-read), runs a one-at-a-time 15-question 3-tier interview (Strategic / Architecture / Quality) with smart-skip and pushback, and generates `prd.json` + `README.md`.

For lightweight planning (small ideas, tweaks, fast captures), use `/plan` instead.

**User's input:** $ARGUMENTS

**Important:** Do NOT implement. Just create the PRD.

## Steps

1. Load the deep-plan skill from `.claude/skills/deep-plan/SKILL.md`
2. Anchor company from first word of `$ARGUMENTS` if it matches a manifest slug; resolve mode (company / repo / personal-HQ)
3. **Repo-run preflight (warn only):** After the company is resolved and the target repo inferred from the manifest, run `bash scripts/repo-run-registry.sh check "$REPO_PATH"`. On exit 2, print the foreign owner row(s) as a `<warning>` block. Do **not** abort — PRD writes normally land in `companies/{co}/projects/{name}/` (outside the owned repo), so the PreToolUse hook will not fire. Warn so the user knows the orchestrator may race on `prd.json` `passes` field writes. PRD does not register itself. Policy: `.claude/policies/repo-run-coordination.md`.
4. Execute the deep flow: company anchor → scan HQ (gated by mode) → infra pre-check → name + brainstorm detection → **Phase 1: research subagents** → **Phase 2: 3-tier deep interview (15 questions, min 10)** → metadata + ops questions → generate prd.json + README → board sync → orchestrator register → beads + learn + doc scout → Linear ({product} only) → confirm + handoff (recommends `/review-plan` next)

## After PRD

- HARD BLOCK: do NOT implement in the same session — PRD creation ends with `/handoff`
- Recommended next session: `/review-plan {name}` — runs adversarial spec review (formerly Step 5.1, now standalone)
- To execute: start a fresh session and run `/run-project {name}` or `/execute-task {name}/US-001`
