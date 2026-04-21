---
description: View and manage OKR structure (objectives, key results) on company boards
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion
argument-hint: [add-objective | add-kr <obj-id> | update-kr <kr-id> <value> | set-status <obj-id> <status> | link-linear <obj-id> <uuid> | link-project <kr-id> <proj-id>] [--company <slug>]
visibility: public
---

# /goals - OKR Management

View and manage objectives + key results on company boards (board.json v2).

**Input:** $ARGUMENTS

## Step 1: Parse Input

Extract from `$ARGUMENTS`:
- `--company <slug>` or `-c <slug>` — explicit company override
- Subcommand (first non-flag word): `add-objective`, `add-kr`, `update-kr`, `set-status`, `link-linear`, `link-project`
- Subcommand args (remaining positional args after subcommand)

If no subcommand → **view mode** (Step 3).

## Step 2: Resolve Company

**Priority order:**
1. `--company` / `-c` flag → use exact slug
2. cwd inside `companies/{slug}/` → infer from path
3. cwd inside `repos/{pub|priv}/{name}` → look up owning company in `companies/manifest.yaml`
4. Default to asking user

Read `companies/manifest.yaml`. Validate company slug exists.
Read `companies/{co}/board.json`. If `schema_version` is missing or < 2, warn: "Board needs migration. Run `npx tsx scripts/migrate-board-v2.ts` first."

## Step 3: View Mode (no subcommand)

Read board.json. Compute metrics:
- Per KR with `source: "derived"`: recompute `current` from linked project statuses (count projects with status in `["done", "completed"]`)
- Per objective: compute overall progress = avg of (KR current/target) across its KRs, or 0% if no KRs

Display OKR tree:

```
OBJECTIVES — {company} [{date}]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[{status-emoji}] {objective title}  ({timeframe})
  Owner: {owner || "unassigned"}
  {if linear_initiative_id: "Linear: {uuid-short}"}

  KR 1: {kr title}
    {progress-bar}  {pct}%  ({current}/{target} {unit})
    Projects: {proj-id} {status-icon}  {proj-id} {status-icon} ...

  KR 2: ...

---

[{status-emoji}] {next objective} ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Unlinked projects: {count}
Total: {obj-count} objectives, {kr-count} KRs, {proj-count} projects
```

**Status emoji mapping:**
- `on_track` → `●` (green context via text)
- `at_risk` → `◐`
- `off_track` → `○`
- `completed` → `✓`
- `paused` → `⏸`

**Progress bar:** Unicode blocks: `████████░░` (10-char bar based on current/target ratio)

## Step 4: add-objective

Ask via AskUserQuestion (batch into 1 call):
1. **Title** — 1-line strategic goal
2. **Description** — optional longer context
3. **Timeframe** — e.g. "2026-H1", "2026-Q2", "2026", "ongoing"
4. **Owner** — free text (person name/slug) or null

After user answers:
1. Read board.json
2. Show existing objectives + existing initiatives. Ask: "Link to existing initiatives?" (multi-select from initiatives list, or "None")
3. If company has `linear` in manifest `services`: ask "Link to Linear initiative UUID?" (text input or skip)
4. Generate ID: `{prefix}-obj-{max+1}` (3-digit zero-padded, same prefix convention as existing objectives)
5. Build objective entry with empty `key_results: []`
6. Append to `objectives[]`, update `updated_at`, write board.json

Print confirmation with the new objective ID.

## Step 5: add-kr {obj-id}

Validate `{obj-id}` exists in objectives[].

Ask via AskUserQuestion (1 call):
1. **Title** — measurable outcome statement
2. **Metric** — machine-readable slug (e.g. "active_users", "revenue_mrr", "features_shipped")
3. **Target** — numeric target value
4. **Current** — numeric current value (default 0)
5. **Unit** — display unit ("users", "%", "$k", "features", etc.)
6. **Direction** — "up" (higher=better) or "down" (lower=better)
7. **Source** — "manual" (you update it) or "derived" (computed from linked project completion)

After user answers:
1. Generate KR ID: `{obj-id}-kr-{N}` where N = existing KR count + 1
2. Set `status` based on current/target ratio: >=70% → on_track, 40-70% → at_risk, <40% → off_track
3. Set `project_ids: []` (link projects separately)
4. Append to objective's `key_results[]`, update `updated_at`, write board.json

If user wants to link projects now, ask: "Link projects to this KR?" Show project list from board, allow multi-select.

## Step 6: update-kr {kr-id} {value}

Parse `{kr-id}` — format is `{obj-id}-kr-{N}`.
Find the objective containing this KR.
Update `current` to `{value}` (parse as number).
Recompute `status`: current/target ratio → on_track/at_risk/off_track/completed.
If current >= target and direction is "up", set status to "completed".
Update `updated_at` on both KR parent objective and board root.
Write board.json.

Print: `Updated {kr-id}: {current}/{target} {unit} ({status})`

## Step 7: set-status {obj-id} {status}

Validate status is one of: `on_track`, `at_risk`, `off_track`, `completed`, `paused`.
Find objective, update its `status` field.
Update `updated_at`, write board.json.

Print: `{obj-id} status → {status}`

## Step 8: link-linear {obj-id} {uuid}

Find objective, set `linear_initiative_id` to `{uuid}`.
Update `updated_at`, write board.json.

If company has `linear` in manifest services, note: "Cross-referenced with Linear initiative {uuid}."
If company does NOT have `linear` in services, warn: "Note: {company} has no Linear integration in manifest."

## Step 9: link-project {kr-id} {proj-id}

Parse `{kr-id}` to find objective + KR.
Validate `{proj-id}` exists in projects[].
Add `{proj-id}` to KR's `project_ids[]` (skip if already present).
Also set `objective_id` on the project entry if not already set (use the KR's parent objective ID).
If KR source is "derived", recompute `current` from linked project statuses.
Update `updated_at`, write board.json.

Print: `Linked {proj-id} to {kr-id} ({project-title})`

## Rules

- **1 AskUserQuestion max per subcommand** — batch all questions
- **board.json is the only file written**
- **Follow existing ID conventions** — prefix from existing entries, zero-padded 3-digit numbers
- **Never block on errors** — if board.json is v1 or malformed, warn and exit gracefully
- **Reindex after writes**: `qmd update 2>/dev/null || true`
