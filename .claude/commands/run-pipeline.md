---
description: "Multi-project pipeline orchestrator — triage, execute, PR, review, deploy with safety gates"
allowed-tools: Bash, Read, Write, Glob, Grep, Edit, AskUserQuestion
argument-hint: "<company> <prd1> [prd2...] [--dry-run] [--resume <id>] [--status]"
visibility: public
---

# /run-pipeline - Multi-Project Pipeline Orchestrator

Orchestrate multiple PRD projects through the full lifecycle: triage, build, PR, review, merge, deploy, canary, done. Wraps `scripts/run-pipeline.sh` — the bash backbone does all heavy lifting. This command provides the intelligent UI: triage presentation, gate interaction, progress display, and dynamic reordering.

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
2. Read relevant files in `.claude/policies/`
3. Count hard vs soft enforcement

Display: `Loaded N policies (H hard, S soft)`

## Step 3 — Triage

Run triage via the bash script in dry-run mode:

```bash
cd /Users/{your-name}/Documents/HQ && bash scripts/run-pipeline.sh {company} {prd1} [prd2...] --dry-run
```

Display the triage table output to the user. This shows: project sequence, risk levels, story counts, repo grouping, dependency order.

Ask user to confirm or reorder the sequence using AskUserQuestion:
- **Proceed** — launch with this sequence
- **Reorder** — user specifies new order, re-display, confirm again
- **Cancel** — stop

If `--dry-run` was in the original args: stop after showing triage (do not launch).

## Step 4 — Launch Pipeline

Run the bash script in background:

```bash
cd /Users/{your-name}/Documents/HQ && \
  nohup bash scripts/run-pipeline.sh {company} {prd1} [prd2...] {passthrough_flags} \
  > workspace/orchestrator/_pipeline/{pipeline_id}/claude-session.log 2>&1 &
echo "PID:$!"
```

**Note:** The script creates the pipeline ID and state dir itself. To get the ID after launch:
1. Wait 3 seconds for state initialization
2. Read the most recently created dir in `workspace/orchestrator/_pipeline/` matching the company slug
3. Read `pipeline-state.json` from that dir to confirm pipeline_id and PID

Display:
> Pipeline launched: **{pipeline_id}** (PID: {pid})
> Monitoring progress... (poll every 30s)

## Step 5 — Poll Loop

Poll `workspace/orchestrator/_pipeline/{pipeline_id}/pipeline-state.json` every 30 seconds.

Each poll iteration:

1. **Read state file**: `jq '.' pipeline-state.json`
2. **Check PID alive**: `kill -0 {pid} 2>/dev/null && echo "ALIVE" || echo "DEAD"`
3. **Detect phase transitions**: compare current phase per project vs last known phase — announce transitions
4. **Display progress**:

```
Pipeline Progress: {pipeline_id}

  project-a    ████████████████     done
  project-b    ██████████░░░░░░     reviewing (PR #42)
  project-c    ░░░░░░░░░░░░░░░░     queued

Progress: 1/3 done | 1 in progress | 1 queued
```

Phase-to-bar mapping (16 chars):
- `queued` = all empty
- `building` = 4 filled
- `pr_open` / `ci_wait` = 6 filled
- `codex_review` / `reviewing` = 8 filled
- `merging` = 10 filled
- `deploying` / `canary` = 12 filled
- `done` = 16 filled
- `failed` = show X marker

5. **Branch on state**:
   - `pending_gate` is non-null → **Step 6 — Gate Handling**
   - Status `completed` or `failed` → **Step 8 — Completion**
   - PID dead + status not terminal → warn user, offer to check logs
   - Otherwise → sleep 30, continue polling

**Poll ceiling:** After 4 hours (480 cycles), warn user and offer to detach. Script keeps running — reattach with `/run-pipeline --status`.

## Step 6 — Gate Handling

When `pending_gate` is detected in pipeline-state.json:

1. **Display gate details**:
   ```
   SAFETY GATE: {gate_name}
   Project: {project}
   Message: {message}
   Requested at: {requested_at}
   ```

2. **Present options** via AskUserQuestion with choices:
   - **Approve** — proceed past this gate
   - **Reject** — fail this project, continue pipeline
   - **Skip** — skip this project entirely

3. **Write resolution** to pipeline-state.json:
   ```bash
   cd /Users/{your-name}/Documents/HQ && \
   jq '.pending_gate.resolution = "{choice}"' \
     workspace/orchestrator/_pipeline/{pipeline_id}/pipeline-state.json > /tmp/ps-tmp.json && \
   mv /tmp/ps-tmp.json workspace/orchestrator/_pipeline/{pipeline_id}/pipeline-state.json
   ```
   Where `{choice}` is `approve`, `reject`, or `skip`.

4. Resume poll loop (Step 5). The bash script detects the resolution and continues.

## Step 7 — Dynamic Reorder

After each project completes (phase transitions to `done` or `failed`), check if multiple projects remain queued. If so:

1. Display current remaining sequence
2. Ask user via AskUserQuestion:
   - **Continue** — keep current order
   - **Reorder** — user specifies new order
3. If reorder: update `.sequence[].order` values in pipeline-state.json via jq, then continue polling

Only offer reorder when 2+ projects remain. Skip for single remaining project.

## Step 8 — Completion

When pipeline status is `completed` or `failed`:

1. Read final pipeline-state.json
2. Display summary table:

```
Pipeline Complete: {pipeline_id}
Duration: {duration}

  Project          Phase      PR       Status
  ─────────────────────────────────────────────
  project-a        done       #41      deployed
  project-b        done       #42      deployed
  project-c        failed     —        build error

Summary: 2 done | 1 failed | 0 skipped
```

3. If failures: list each failed project with its `error` field
4. Show path to full logs: `workspace/orchestrator/_pipeline/{pipeline_id}/`

## Step 9 — Resume

When `--resume <pipeline_id>` is provided:

1. Read `workspace/orchestrator/_pipeline/{pipeline_id}/pipeline-state.json`
2. Validate it exists and status is not `completed`
3. Display current state (same format as poll output)
4. Extract PID from state, check if alive:
   - PID alive → resume poll loop (Step 5)
   - PID dead + status `in_progress` → offer to relaunch:
     ```bash
     cd /Users/{your-name}/Documents/HQ && \
       nohup bash scripts/run-pipeline.sh --resume {pipeline_id} \
       > workspace/orchestrator/_pipeline/{pipeline_id}/claude-session.log 2>&1 &
     ```
   - PID dead + status `paused`/`failed` → display error context, ask user for next action

## Status Display

When `--status` is provided:

```bash
cd /Users/{your-name}/Documents/HQ && bash scripts/run-pipeline.sh --status
```

Display the formatted output and stop.

## Rules

- **State file is the interface** — bash script writes it, this command reads it. Only write to `pending_gate.resolution` and `sequence[].order`
- **AskUserQuestion for gates** — never auto-approve. Always present gate details and let user decide
- **`pre_deploy_prod` and `canary_failure` gates are always gated** — cannot be overridden even in autonomous mode
- **Never kill the bash script** unless user explicitly asks to abort
- **Pipeline isolation** — one company per pipeline. Never mix PRDs from different companies
- **Passthrough flags** — flags not consumed by this command pass through to `scripts/run-pipeline.sh` verbatim
- **Config source** — `settings/pipeline.yaml` controls gate defaults, polling intervals, deploy behavior. The bash script reads it; this command does not need to parse it directly
- **State dir** — `workspace/orchestrator/_pipeline/{pipeline_id}/` contains `pipeline-state.json` and logs
