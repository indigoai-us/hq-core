---
name: run-pipeline
description: Multi-project pipeline orchestrator — triage, execute, PR, review, deploy with safety gates
allowed-tools: Bash, Read, Write, Glob, Grep, Edit, AskUserQuestion
---

# /run-pipeline - Multi-Project Pipeline Orchestrator

Orchestrate multiple PRD projects through the full lifecycle: triage, build, PR, review, merge, deploy, canary, done.

This command has no separate bash backbone in core. Do not invent one. After the user confirms order, run `/run-project` once per PRD.

**Arguments:** $ARGUMENTS

## Step 1 — Parse Arguments

Parse `$ARGUMENTS` into:
- `company` — company slug (first positional arg)
- `prd_paths` — one or more PRD paths (remaining positional args)
- Flags: `--dry-run`, `--resume <id>`, `--status`, plus any passthrough flags

**Routing:**
- No args → print usage summary and stop:
  ```
  Usage: /run-pipeline <company> <prd1> [prd2...] [flags]
         /run-pipeline --resume <pipeline-id>
         /run-pipeline --status

  Flags: --dry-run, --model MODEL, --timeout N, --verbose,
         --auto-merge-all, --gate-all-merges, --skip-canary,
         --skip-failed-projects, --auto-sst-deploy
  ```
- `--status` → jump to **Status Display** (below)
- `--resume <id>` → jump to **Step 9 — Resume**
- Otherwise → continue to Step 2

## Step 2 — Load Policies

Standard policy loading protocol:

1. Read all files in `companies/{company}/policies/` (skip `example-policy.md`)
2. Read relevant files in `core/policies/`
3. Count hard vs soft enforcement

Display: `Loaded N policies (H hard, S soft)`

## Step 3 — Triage

List the PRDs in argument order. For each, read `prd.json` metadata if present (name, story count, repo). Show a table: sequence, risk if known, story counts, repo grouping.

Ask the user to confirm or reorder using AskUserQuestion:
- **Proceed** — run `/run-project` for each PRD in this sequence
- **Reorder** — user specifies new order, re-display, confirm again
- **Cancel** — stop

If `--dry-run` was in the original args: stop after showing triage (do not launch).

## Step 4 — Launch

For each PRD in the confirmed order, run `/run-project` with that PRD and any passthrough flags that `/run-project` accepts. Wait for each to finish before starting the next, unless the user asked to overlap.

Do not background a missing shell script. Do not write a replacement orchestrator script.

Display:
> Running `/run-project` for **{prd}** ({index}/{total})

## Step 5–8 — Per-project gates

`/run-project` owns build, PR, review, merge, and deploy gates for that PRD. Surface its questions to the user. Never auto-approve `pre_deploy_prod` or `canary_failure`.

## Step 9 — Resume

When `--resume <pipeline_id>` is provided:

1. Read `workspace/orchestrator/_pipeline/{pipeline_id}/pipeline-state.json` if it exists
2. If it does not exist, say resume is unavailable without a prior pipeline state file, and stop
3. If it exists, display current state and continue any unfinished PRDs with `/run-project`

## Status Display

When `--status` is provided:

1. List `workspace/orchestrator/_pipeline/` if it exists
2. For the newest (or named) pipeline, read `pipeline-state.json` when present
3. If none exist, say there is no pipeline state on disk
4. Display what you found and stop

## Rules

- **AskUserQuestion for gates** — never auto-approve. Always present gate details and let the user decide
- **`pre_deploy_prod` and `canary_failure` gates are always gated** — cannot be overridden even in autonomous mode
- **Pipeline isolation** — one company per pipeline. Never mix PRDs from different companies
- **No invented backbone** — do not add a core pipeline shell script from this skill
- **State dir** — `workspace/orchestrator/_pipeline/{pipeline_id}/` may contain `pipeline-state.json` and logs from older runs
