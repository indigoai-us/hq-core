---
name: garden
description: Audit HQ content for stale, duplicate, or inaccurate information.
allowed-tools: Task, Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
---

# /garden - HQ Content Gardener

Multi-worker audit pipeline: Scout → Auditor → Curator. Detects stale content, duplicates, orphans, INDEX drift, conflicts, and unowned files. Human approval gates between each phase.

**Arguments:** $ARGUMENTS

## Usage

```
/garden {product}                    # Audit one company (all its dirs)
/garden companies/{company}/knowledge/    # Audit specific directory
/garden personal/projects/             # Audit personal/HQ projects
/garden all                            # Full HQ sweep (chunked by company + orphan sweep)
/garden --resume {run-id}              # Resume interrupted run
/garden --status                       # Show active/past garden runs
/garden policies [--dry-run]           # Retire personal + active-company policies by evidence
/garden policies --deep                # Reviewed trim: full-read every policy, approve per group, delete with backup
```

---

## Policies Pass (`/garden policies`)

Retires personal and company policies by evidence so the corpus fades on its
own. Retirement is never gated on human review: the pass retires, reports, and
a wrong call is reversed with `bash core/scripts/policy-retire.sh <id> --restore`.
It runs on its own and is not part of the Scout → Auditor → Curator pipeline
below. The approval gates there do not apply to this pass.

1. Resolve the active company (`hq-session.sh get company_slug`). Scope is
   `personal/policies` and `companies/<active>/policies` only. Never retire
   anything in `core/policies`
   (hq-retire-generated-artifacts-by-usage-do-not-gate-creation).
2. Read the evidence: `bash core/scripts/policy-retrieval-report.sh
   personal/policies companies/<active>/policies` (last retrieval per policy).
3. Select candidates with `bash core/scripts/garden-policy-pass.sh --company
   <active> --dry-run`. It prints one row per policy (decision, id, path,
   reason). A policy is a candidate when any one of these holds:
   - zero retrievals in 90 days and `created:` more than 90 days ago;
   - `status: superseded` and an active policy lists it in `supersedes:`;
   - `retire_when:` is present and you judge the condition met. The script
     marks these rows `judge`. Read each one, check the condition against the
     current state (installed versions, shipped fixes, existing files), and
     write one sentence of reasoning per candidate, whether met or not.
4. Run it for real: `bash core/scripts/garden-policy-pass.sh --company
   <active> [--retire-when-met <id>=<reasoning>]...`. Each candidate is retired
   through `core/scripts/policy-retire.sh` (`hq core policy retire`), which
   sets `status: retired`, `retired_at`, `retired_by`, `retired_reason`. Never
   edit policy frontmatter by hand.
5. Retired files stay in place. Do not move, delete, or archive them. The only
   effect on injection is the staleness order from the trigger loader.
6. Print the summary line the script ends with (how many evaluated, retired,
   and skipped and why). It is also written to
   `workspace/reports/garden/policies-<YYYY-MM-DD>.md`, together with the
   per-policy table and your `retire_when` reasoning.

`--dry-run` lists candidates without retiring anything. Use it for a first
run on a new machine, review the list against the rules above yourself, then
run for real.

---

## Deep Policies Pass (`/garden policies --deep`)

A reviewed trim for a policy corpus that has grown past what usage evidence
can thin out. Subagents read every policy in full and assign a verdict; the
user approves each verdict group; approved files are backed up and deleted.
Unlike the evidence pass above, every destructive step waits for the user.
The mechanical steps run through `core/scripts/garden-policy-deep.py`; the
judgment is yours and the reviewers'.

### Scope

- `personal/policies`, plus `companies/<co>/policies` only for companies in
  the session's locked company set. Ask before adding a company folder.
- Never `core/policies`. The script refuses it. Core rules change through
  hq-core-staging.
- Never move a rule from one company's folder into another's. A rule that
  belongs to a different company is a delete candidate or stays put.

### Steps

1. **Warn about sync first.** Before any delete, tell the user that deletes
   in a synced folder propagate to their other machines on the next sync,
   and that every round is backed up to a tarball that can be restored.
2. **Inventory.**
   `python3 core/scripts/garden-policy-deep.py inventory --dir personal/policies [--dir companies/<co>/policies] --out workspace/reports/garden/deep-<YYYY-MM-DD>`
   It prints counts, already-retired files, frontmatter that does not parse,
   retrieval bands, and creation months, and writes review batches.
   Retrieval counts mostly measure how broad a trigger is, not whether a rule
   helps; do not treat a high count as a reason to keep.
3. **Repair broken frontmatter** before review, with Edit (quote values that
   contain `: `, fix orphan lists and invalid `when:` expressions). A policy
   whose frontmatter does not parse never fires; that is a repair, not a trim.
4. **Interview** the user with one `AskUserQuestion` about tools, flows, and
   companies they no longer use. Pass the answers into every reviewer brief.
5. **Review.** Spawn one `general-purpose` subagent per batch (about 175
   files each), in parallel, read-only except its output file
   `<run>/review-NN.json`. The brief must require:
   - reading every file's full text (print files whole from one python script,
     in chunks; per-file `cat` may be hook-blocked), never judging from a title
     or digest line, because a title is not enough to justify a deletion;
   - one verdict per file from this rubric:
     - `personal-keep`: the user's own preference, voice, taste, or workflow
       choice, or something specific to this machine;
     - `core-policy`: an HQ rule every install would benefit from;
     - `core-fix`: works around a bug or rough edge in an HQ script, hook, or
       skill; name the real path (skills live in `.claude/skills/<name>`);
     - `delete-covered`: core, the charter, or a skill already says it; name it;
     - `delete-dup`: repeats another kept policy; name the twin;
     - `delete-generic`: practice a strong model follows unprompted;
     - `delete-narrow`: an incident note or a one-time API or tool quirk;
     - `delete-stale`: depends on something gone; cite the missing file,
       flag, or tool;
   - keeping hard rules about deletes, secrets, outbound sends, deploy gates,
     production writes, or company isolation unless a twin or the missing
     dependency is named;
   - never writing a `companies/` path literally in a Bash command.
6. **Merge.** `python3 core/scripts/garden-policy-deep.py merge --out <run>`
   fails if any file lacks a verdict, and keeps a duplicate whose twin is
   also flagged. Spot-check a sample of `delete-covered` and `delete-stale`
   claims yourself before presenting them.
7. **Decide, one group at a time.** One `AskUserQuestion` per group,
   recommended option first, with counts and two or three concrete examples:
   stale and covered; duplicates; narrow soft; narrow hard (read these
   yourself and propose which to keep); `core-policy` and `core-fix`. For
   the core groups, offer: delete the personal copies; file them as core work
   (`/hq-bug` for most users; an hq-core-staging project for maintainers),
   then delete; or keep until the core change lands. An approval covers only
   the group asked about.
8. **Apply each approved group.**
   `python3 core/scripts/garden-policy-deep.py apply --out <run> --verdict <v> [--verdict <v>] [--enforcement hard|soft] [--exclude <file>]`
   prints a dry run. Re-run with `--confirm` to tar the files into
   `workspace/orchestrator/policy-lifecycle/backups/garden-deep-<ts>.tar.gz`,
   verify the tarball, delete, and log the list to `<run>/applied.log`. This
   deletes through a script, which bypasses the policy-folder write guard, so
   say so in the question that asks for approval. If the user prefers, retire
   instead with `core/scripts/policy-retire.sh`.
9. **Undo** with `python3 core/scripts/garden-policy-deep.py restore --backup <tarball>`.
10. **Report.** Write `<run>/report.md`: before and after counts (hard and
    soft), each round's decision, backup path, and every removed file with
    its verdict and reason. If the install keeps a generated `_digest.md` for
    the folder, regenerate it. Give the user the counts, the backup paths,
    and the report link in plain words.

The pass can repeat: after a first round, run it again on the keeps with a
stricter bar (keep only personal preferences and safety gates that core does
not already cover).

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
    workers matching company:{scope}  # from worker.company field in each worker.yaml (registry surfaces this)
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
  personal/projects/ (personal/HQ projects)
  core/workers/public/ (non-team, non-company workers)
```

**`personal/projects/`** or other HQ-level dir:
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
  - core/workers/public/gardener-team/garden-scout/worker.yaml
  - core/workers/public/gardener-team/garden-scout/skills/scan-scope.md

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
  - core/workers/public/gardener-team/garden-auditor/worker.yaml
  - core/workers/public/gardener-team/garden-auditor/skills/validate-findings.md

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
  - core/workers/public/gardener-team/garden-curator/worker.yaml
  - core/workers/public/gardener-team/garden-curator/skills/execute-actions.md

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
- Company knowledge is a plain directory synced through the company vault; do not initialize or commit Git there
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
