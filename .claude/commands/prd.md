---
description: Lightweight PRD creation — batched interview + execution plan
allowed-tools: Read, Glob, Grep, Write, Bash, AskUserQuestion
argument-hint: [project/feature description]
visibility: public
---

# /prd — Project Planning & PRD Generation

Run the `/prd` skill to scan HQ context, interview the user in batches, and generate execution-ready PRD files (`prd.json` + `README.md`). Runtime-agnostic canonical logic lives in the skill.

For **large, strategically important PRDs** that warrant 10–15 min of upfront research + a 15-question 3-tier interview, use `/deep-plan` instead.

**User's input:** $ARGUMENTS

**Important:** Do NOT implement. Just create the PRD.

## Steps

1. Load the PRD skill from `.claude/skills/prd/SKILL.md`
2. Anchor company from first word of `$ARGUMENTS` if it matches a manifest slug; resolve mode (company / repo / personal-HQ)
3. **Repo-run preflight (warn only):** After the company is resolved and the target repo inferred from the manifest, run `bash core/scripts/repo-run-registry.sh check "$REPO_PATH"`. On exit 2, print the foreign owner row(s) as a `<warning>` block. Do **not** abort — PRD writes normally land in `companies/{co}/projects/{name}/` (outside the owned repo), so the PreToolUse hook will not fire. Warn so the user knows the orchestrator may race on `prd.json` `passes` field writes. PRD does not register itself. Policy: `core/policies/repo-run-coordination.md`.
4. Execute the lightweight flow: company anchor → scan HQ (gated by mode) → infra pre-check → name + brainstorm detection → batched interview → live-path-watch hook → generate prd.json + README → board sync → orchestrator register → beads + learn + doc scout → Linear ({product} only) → confirm + handoff

## After PRD

- HARD BLOCK: do NOT implement in the same session — PRD creation ends with `/handoff`
- For adversarial spec review, run `/review-plan {name}` in a fresh session
- To execute: start a fresh session and run `/run-project {name}` or `/execute-task {name}/US-001`
