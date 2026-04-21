---
description: Audit and clean HQ content — detect stale, duplicate, and inaccurate information
allowed-tools: Task, Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
argument-hint: [scope] or [--resume run-id] or [--status]
visibility: public
---

# /garden - HQ Content Gardener

Multi-worker audit pipeline: Scout → Auditor → Curator. Detects stale content, duplicates, orphans, INDEX drift, conflicts, and unowned files. Human approval gates between each phase.

**Arguments:** $ARGUMENTS

## Usage

```
/garden {product}                    # Audit one company (all its dirs)
/garden companies/{company}/knowledge/    # Audit specific directory
/garden projects/                      # Audit all projects
/garden all                            # Full HQ sweep (chunked by company + orphan sweep)
/garden --resume {run-id}              # Resume interrupted run
/garden --status                       # Show active/past garden runs
```

---

## Process

### 0. Parse Arguments

**If `--status`:**
- Scan `workspace/orchestrator/garden-*/state.json`
- Display table: run_id | scope | status | phase | findings | actions | date
- Exit

**If `--resume {run-id}`:**
- Load state from `workspace/orchestrator/garden-{run-id}/state.json`
- Resume from last incomplete phase
- If phase was "scout" → re-run scout
- If phase was "auditor" → load findings.json, go to human gate before audit
- If phase was "curator" → load audit-report.json, go to human gate before curate

**If `{scope}`:**
- Resolve scope (Step 1)
- Check for existing run with same scope → offer resume or fresh start
- Initialize new run

### 1. Scope Resolution

Resolve the argument to a list of concrete directory paths.

**Company slug** (matches key in `companies/manifest.yaml`):
```
Read companies/manifest.yaml
For company = {scope}:
  paths = [
    companies/{scope}/               # company dir + knowledge
    workers matching company:{scope}  # from registry.yaml
    projects matching manifest repos  # project dirs related to company
    workspace/orchestrator/*{scope}*  # orchestrator state for company projects
  ]
```

**Direct path** (contains `/`):
```
Validate path exists
paths = [{scope}]  # just that directory tree
```

**`all`** (full sweep):
```
Read companies/manifest.yaml → get all company slugs
chunks = company slugs + ["_orphans"]
Process each chunk sequentially (scout→audit→curate per chunk)
_orphans chunk = everything not claimed by any company:
  workspace/threads/
  workspace/reports/
  workspace/insights/ (global/tools/concepts — not company-scoped)
  workspace/orchestrator/ (runs not tied to a company)
  projects/ (projects not matching any company repo)
  workers/public/ (non-team, non-company workers)
```

**`projects/`** or other HQ-level dir:
```
paths = [{scope}]
```

### 2. Initialize State

```json
// Write to workspace/orchestrator/garden-{run-id}/state.json
{
  "run_id": "garden-{slug}-{YYYYMMDD}",
  "scope": "{original argument}",
  "resolved_paths": ["..."],
  "status": "in_progress",
  "phase": "scout",
  "started_at": "ISO8601",
  "updated_at": "ISO8601",
  "findings_count": 0,
  "approved_count": 0,
  "actions_taken": 0,
  "prds_created": []
}
```

Run ID format:
- Company: `garden-{company}-{YYYYMMDD}` (e.g. `garden-{product}-20260219`)
- Path: `garden-{dirname}-{YYYYMMDD}` (e.g. `garden-projects-20260219`)
- All: `garden-all-{YYYYMMDD}`

### 3. Scout Phase

Spawn garden-scout worker via Task tool:

```
Task(
  subagent_type: "general-purpose",
  model: "haiku",
  prompt: """
  You are garden-scout. Read your worker config and scan-scope skill:
  - workers/public/gardener-team/garden-scout/worker.yaml
  - workers/public/gardener-team/garden-scout/skills/scan-scope.md

  Context:
  - run_id: {run_id}
  - resolved_paths: {resolved_paths}
  - output_path: workspace/orchestrator/garden-{run_id}/findings.json

  Execute the scan-scope skill. Write findings.json to the output path.
  Return a JSON summary: {"findings_count": N, "by_type": {...}, "by_severity": {...}}
  """
)
```

After scout returns:
- Read findings.json
- Update state.json: phase → "scout_complete", findings_count
- Display findings summary to human

**HUMAN GATE:**
```
Present findings summary table:
| Type | Count | High | Med | Low |
Show top 10 highest-severity findings with paths and signals.

Ask: "Approve all findings for audit, or filter? (all / filter / abort)"
- all → approved_ids = all finding IDs
- filter → show each finding, human approves/rejects
- abort → set status "paused", exit
```

### 4. Auditor Phase

Spawn garden-auditor worker via Task tool:

```
Task(
  subagent_type: "general-purpose",
  model: "sonnet",
  prompt: """
  You are garden-auditor. Read your worker config and validate-findings skill:
  - workers/public/gardener-team/garden-auditor/worker.yaml
  - workers/public/gardener-team/garden-auditor/skills/validate-findings.md

  Context:
  - run_id: {run_id}
  - findings_path: workspace/orchestrator/garden-{run_id}/findings.json
  - output_path: workspace/orchestrator/garden-{run_id}/audit-report.json
  - approved_ids: {approved_finding_ids}

  Execute the validate-findings skill. Write audit-report.json to the output path.
  Return a JSON summary: {"audited": N, "actions": {...}, "escalations": [...]}
  """
)
```

After auditor returns:
- Read audit-report.json
- Update state.json: phase → "auditor_complete"
- Display audit summary to human

**HUMAN GATE:**
```
Present audit results table:
| Finding | Validation | Action | Confidence |
Show escalations (needs-discovery) separately.

Ask: "Approve all actions, or review individually? (all / review / abort)"
- all → approved_ids = all non-skip finding IDs
- review → show each action, human approves/rejects/modifies
- abort → set status "paused", exit
```

### 5. Curator Phase

Spawn garden-curator worker via Task tool:

```
Task(
  subagent_type: "general-purpose",
  model: "sonnet",
  prompt: """
  You are garden-curator. Read your worker config and execute-actions skill:
  - workers/public/gardener-team/garden-curator/worker.yaml
  - workers/public/gardener-team/garden-curator/skills/execute-actions.md

  Context:
  - run_id: {run_id}
  - audit_path: workspace/orchestrator/garden-{run_id}/audit-report.json
  - output_path: workspace/orchestrator/garden-{run_id}/actions-log.json
  - approved_ids: {approved_action_ids}

  Execute the execute-actions skill. Write actions-log.json to the output path.
  Return a JSON summary: {"succeeded": N, "failed": N, "prds_created": [...], "repos_committed": [...]}
  """
)
```

After curator returns:
- Read actions-log.json
- Update state.json: phase → "complete", actions_taken, prds_created

### 6. Report

Generate summary report:

```markdown
// Write to workspace/reports/garden/{run_id}.md

# Garden Report: {scope}
**Run:** {run_id} | **Date:** {date}

## Summary
- Files scanned: {N}
- Findings: {N} ({high} high, {med} medium, {low} low)
- Actions taken: {N} ({archived} archived, {deduped} deduped, {updated} updated, {cleaned} cleaned)
- Escalations: {N} PRDs created

## Actions Taken
| Finding | Action | Before | After |
...

## Escalations Created
| PRD | Title | Source Finding |
...

## Failed Actions
| Finding | Error |
...
```

Post-report:
- Run `qmd update 2>/dev/null || true`
- Regenerate affected INDEX.md files
- Log garden run completion timestamp to state.json

### 7. All-Sweep Loop (only for `/garden all`)

If scope is "all":
```
chunks = [company1, company2, ..., "_orphans"]
for chunk in chunks:
  Run Steps 1-6 for this chunk
  run_id = garden-all-{YYYYMMDD}-{chunk}
  State stored in workspace/orchestrator/garden-all-{YYYYMMDD}/
  Human gates per chunk (not batched across all companies)
```

After all chunks:
- Generate aggregate report at `workspace/reports/garden/garden-all-{YYYYMMDD}.md`
- Summarize per-company findings + actions

---

## Rules

- ONE garden run at a time (check for in_progress runs before starting)
- NEVER delete without archival — curator moves to _archive/ first
- NEVER skip human gates — always present findings/actions for approval
- Knowledge repo commits go to TARGET repo, not HQ git
- Always verify `git branch --show-current` before any commit
- For "all" sweep: chunk by company, sequential, human gate per chunk
- Scout is read-only. Auditor is read-only. Only Curator modifies files.
- State files enable resume — always update state.json after each phase
- If context gets long, /handoff between chunks (for "all" sweep)
- After garden completion, log timestamp so /nexttask can track freshness

## Model Routing

| Worker | Model | Rationale |
|--------|-------|-----------|
| garden-scout | haiku | Fast scan, pattern matching, no deep analysis |
| garden-auditor | sonnet | Reads content, cross-references, makes judgments |
| garden-curator | sonnet | Executes file ops, commits, creates PRDs |
