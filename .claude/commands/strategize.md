---
description: Strategic prioritization — "what should I work on next?" with optional deep review
allowed-tools: Read, Write, Bash, AskUserQuestion
argument-hint: [company-slug] [--deep]
visibility: public
---

# /strategize - Strategic Prioritization

Answer "what should I work on next?" Quick mode gives a prioritized 3-5 list. Deep mode writes a full strategic review.

**Input:** $ARGUMENTS

**Pipeline:** `/idea` → `/brainstorm` → `/plan` → **`/strategize`** → `/run-project`

## Step 0: Parse Input & Company Anchor

Check if **first word** of `$ARGUMENTS` matches a company slug in `companies/manifest.yaml`.

**How to check:** Read `companies/manifest.yaml`. Extract top-level keys (company slugs). If the first word of `$ARGUMENTS` exactly matches one:

1. **Set `{co}`** = matched slug. Strip from `$ARGUMENTS`
2. **Announce:** "Anchored on **{co}**"

**If no match** → company resolved in Step 1.

**Flag detection:** Check remaining args for `--deep`. If found, set `mode = deep`, strip flag. Default: `mode = quick`.

## Step 1: Resolve Company

**If `{co}` already set from Step 0:** skip to Step 2.

**Priority order:**
1. cwd inside `companies/{slug}/` → infer from path
2. cwd inside `repos/{pub|priv}/{name}` → manifest lookup for owning company
3. Ask via AskUserQuestion: "Which company?" — list slugs that have board.json

Read `companies/{co}/board.json`. If file doesn't exist: "No board.json for {co}. Run `/idea` to start one." — exit.
If `schema_version` < 2 or missing: warn "Board is v1 — objective analysis unavailable. Showing project-only view." — proceed with projects only.

## Step 2: Load Board Data

From `companies/{co}/board.json` extract:
- `objectives[]` with their `key_results[]`
- `projects[]` — **exclude** status `archived`

**PRD reads:** For each non-archived project where `prd_path` is set AND status is `in_progress` or `prd_created`:
- Read the prd.json file at the path
- Extract: `story_total` = `userStories.length`, `story_done` = count where `passes === true`, `prd_status` = `metadata.status`
- **Cap at 15 prd.json reads** — prioritize `in_progress` first, then `prd_created`
- If file doesn't exist at `prd_path`, skip silently (note "PRD not found" in output)

## Step 3: Compute Signals

### A. STALLED
Projects where:
- Board status = `in_progress`
- Story completion < 25% (or 0 done out of 3+ total)
- Has `prd_path` (distinguishes real projects from ideas marked in_progress)

### B. READY
Projects where:
- Board status = `prd_created` OR `prd_status` = `ready`
- Has valid `prd_path`
- Story completion = 0% (not started)

### C. ALIGNED-IDEA
Projects where:
- Board status = `idea` or `exploring`
- Has `objective_id` (aligned to an objective)
- No `prd_path` set

### D. COVERAGE-GAP
For each objective: collect all linked project IDs from `key_results[].project_ids` + projects with matching `objective_id`. If NO linked project has status `in_progress` or `prd_created` → objective has no active work.

### E. Capacity (context only)
Count projects with board status `in_progress`.

## Step 4: Score & Rank

**Internal scoring (not shown to user):**
- `READY`: base 80 + 10 if `objective_id` set
- `ALIGNED-IDEA`: base 60 + 20 if `brainstorm_path` exists
- `STALLED`: base 40 + 20 if >50% stories done (almost there), -20 if 0% done and >5 stories
- `COVERAGE-GAP`: base 30

Pick top 3-5 across all signal types. Deduplicate (same project can't appear twice). Tiebreak: READY > ALIGNED-IDEA > STALLED > COVERAGE-GAP.

## Step 5: Output — Quick Mode

Print to terminal:

```
STRATEGY — {company} [{date}]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

In flight: {N} active  |  {M} ready  |  {K} stalled

TOP PRIORITIES
━━━━━━━━━━━━━━

1. [READY] {project title}
   Why: {1-sentence reasoning — alignment, effort, momentum}
   State: {status} | {done}/{total} stories | Obj: {obj-title or "unaligned"}
   Next: /run-project {prd-slug}

2. [STALLED] {project title}
   Why: {reasoning}
   State: {status} | {done}/{total} stories | Obj: {obj-title or "unaligned"}
   Next: /run-project {prd-slug}

... (up to 5)
```

**Signal labels:** `[READY]` `[STALLED]` `[IDEA]` `[GAP]`

**If COVERAGE-GAP detected but not in top 5:**
`Note: "{obj-title}" has no active projects.`

**If >10 in-flight projects:**
`Note: {N} concurrent projects — consider completing before starting new work.`

**Next action routing table:**

| Project state | Suggested action |
|---|---|
| `idea`, no brainstorm | `/brainstorm {co} {slug}` |
| `exploring`, has brainstorm | `/plan {co} {slug}` |
| `prd_created` or `ready` | `/run-project {prd-slug}` |
| `in_progress`, stalled | `/run-project {prd-slug}` (resume) |
| COVERAGE-GAP (no project) | `/idea {co} --objective {obj-id}` |

Then **AskUserQuestion** with options:

1. Act on #1 — {title} ({next-action-verb})
2. Act on #2 — {title} ({next-action-verb})
3. Act on #3 — {title} ({next-action-verb})
4. Run deep review (`--deep`)

When user picks an option: **execute the routed command** (e.g., invoke `/run-project`, `/brainstorm`, `/plan`, or `/idea`).

## Step 6: Output — Deep Mode

Everything in Step 5 PLUS generate a markdown report.

### Additional analysis:

**OKR Progress** — For each objective:
- List KRs with progress (current/target, %). Derived KRs: recompute `current` from linked project completion counts
- Status: >=70% → on_track, 40-69% → at_risk, <40% → off_track
- Flag objectives with ALL KRs off_track or NO KRs as `AT-RISK`

**Project Funnel:**
```
idea: N  →  exploring: N  →  prd_created: N  →  in_progress: N  →  done: N
```
Assess: top-heavy (many ideas, few executing), balanced, or bottom-heavy.

**Unaligned Work** — All `in_progress` or `prd_created` projects with no `objective_id`.

**Capacity** — Flag if in_progress > 5: "High WIP — consider completing before starting."

**Write report to:** `workspace/reports/{co}-strategy-review.md`

```markdown
# {Company} Strategic Review
_Generated {date}_

## Summary
{2-3 sentence executive summary}

## Capacity
{N} projects in flight. {Assessment: focused/overloaded/underleveraged}

## OKR Coverage
| Objective | KRs | Progress | Status |
|---|---|---|---|
| {title} | {count} | {avg %}  | {status} |

### At-Risk Objectives
{List with reasoning, or "None"}

## Project Funnel
{Text funnel + assessment}

## Top Priorities
{Same 3-5 list from quick mode with fuller reasoning}

## Unaligned Work
| ID | Title | Status |
|---|---|---|
{Projects with no objective_id}

## Recommended Actions
{Numbered list matching priorities with full commands}
```

After writing: `qmd update 2>/dev/null || true`

Print: `Report written: workspace/reports/{co}-strategy-review.md`

Then present same AskUserQuestion as quick mode.

## Rules

- **Read-only** — no board.json writes, no Linear API calls, no PRD modifications
- **15 prd.json reads max** — prevent timeout on large boards
- **No HTML** — this command is text/markdown only
- **No brainstorm.md** — that is `/brainstorm`. This command ROUTES to it
- **1 AskUserQuestion max for clarification** (Step 1). 1 for action routing (Step 5/6). Never batched together
- **Skip archived projects** — don't surface, don't count
- **Staleness = story completion %** — primary signal. `updated_at` is unreliable (mass-set dates). Say "0/8 stories complete" not "inactive for 30 days"
- **Graceful on missing data** — no prd_path → skip story count, show "no PRD". No objectives → skip OKR sections. No KRs → flag as "needs KRs"
- **Company isolation** — scope all reads to `companies/{co}/`. Never mix company data
- **Deep mode writes exactly 1 file** — `workspace/reports/{co}-strategy-review.md`
- **Do NOT use TodoWrite or EnterPlanMode**
