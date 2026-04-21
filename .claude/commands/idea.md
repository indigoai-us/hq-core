---
description: Capture a project idea on the board without a full PRD
allowed-tools: Read, Write, Bash, AskUserQuestion
argument-hint: [idea description] [--company <slug>] [--app <repo-name>]
visibility: public
---

# /idea - Capture Project Idea

Quickly add a project idea to the board. No PRD, no stories — just capture the thought.

**Input:** $ARGUMENTS

## Step 1: Parse Input

Extract from `$ARGUMENTS`:
- `--company <slug>` or `-c <slug>` — explicit company override
- `--app <repo-name>` — target repo/app (sets `scope: "app"`)
- Everything else → idea description text

If `$ARGUMENTS` is empty and no flags, go to Step 2 (full interview).
If description text is present (>5 words after flag extraction), skip the description question in Step 3.

## Step 2: Resolve Company

**Priority order:**
1. `--company` / `-c` flag → use exact slug
2. cwd inside `companies/{slug}/` → infer from path
3. cwd inside `repos/{pub|priv}/{name}` → look up owning company in `companies/manifest.yaml`
4. If still ambiguous → ask in Step 3

Read `companies/manifest.yaml`. Validate company slug exists and has a non-empty `board_path`.

If `board_path` is empty or missing:
- Ask: "Company {slug} has no board. Create one? [Y/n]"
- If yes: write fresh board.json at `companies/{slug}/board.json` with `{"company":"{slug}","updated_at":"ISO8601","initiatives":[],"projects":[]}`, update manifest `board_path`
- If no: abort

## Step 3: Interview (1 AskUserQuestion call)

Batch all missing info into **one** AskUserQuestion call. Skip any field already resolved from args/context.

**Questions (include only what's missing):**

1. **What's the idea?** (1-2 sentences)
   *Skip if description already extracted from args.*

2. **Scope?**
   - A. Company-wide (no specific repo)
   - B. App/repo → list company repos from manifest as sub-options
   *Skip if `--app` flag provided or company has no repos.*

3. **Goal alignment?** (optional)
   If board `schema_version >= 2` and `objectives[]` is non-empty, list objectives:
   ```
   1. {obj-title-1}
   2. {obj-title-2}
   N. None
   ```
   If board is v1 or has no objectives, fall back to listing active initiatives:
   ```
   1. {init-title-1}
   2. {init-title-2}
   N. None
   ```
   *If board has neither objectives nor active initiatives, skip and default to null.*

If company was unresolved in Step 2, prepend a company question:
- **Which company?** List all companies from manifest that have a `board_path`.

**Target: 1 AskUserQuestion call total.** If everything is provided via args (description + company + app), skip straight to Step 4 — no interview needed.

## Step 4: Write Board Entry

1. Read `companies/{co}/board.json`
2. **Generate ID:**
   - Collect all `id` values from `projects` array
   - Extract numeric suffixes from IDs matching `{prefix}-proj-{NNN}` pattern
   - Next ID = `{prefix}-proj-{max_N + 1}`, zero-padded to 3 digits (4+ if >999)
   - Use the lowercase prefix convention from existing entries (e.g. `lr`, `ab`, `pe`)
3. **Derive title:** If description is >50 chars, derive a concise 3-6 word title. If ≤50 chars, use as-is for both title and description.
4. **Build entry:**
   ```json
   {
     "id": "{prefix}-proj-{NNN}",
     "title": "{concise title}",
     "description": "{user's full description}",
     "status": "idea",
     "scope": "company|app",
     "app": "{repo-name|null}",
     "initiative_id": "{xx-init-NNN|null}",
     "objective_id": "{xx-obj-NNN|null}",
     "prd_path": null,
     "created_at": "{ISO8601}",
     "updated_at": "{ISO8601}"
   }
   ```
   If user selected an objective in Step 3, set `objective_id` to that objective's ID. Also find the objective's `initiative_ids[0]` (if any) and set `initiative_id` for backward compatibility.
5. Append to `projects` array. Update root `updated_at`. Write board.json.

## Step 5: Confirm & Reindex

Print:
```
Idea captured: **{title}** ({id})
Board: companies/{co}/board.json
Status: idea

Next steps:
  /plan {title}             → promote to full PRD
  /idea                     → add another idea
  /idea --company {co}      → add idea to same board
```

Reindex: `qmd update 2>/dev/null || true`

## Rules

- **No PRD files** — this command ONLY writes to board.json
- **No orchestrator registration** — ideas are not executable; `/plan` handles that on promotion
- **No Linear sync** — ideas are pre-planning; Linear sync happens at `/plan` time
- **1 AskUserQuestion max** — batch everything into one call
- **No TodoWrite** — single-step output, not needed
- **No EnterPlanMode** — this command IS the quick capture
- **Board.json is the only file written** (plus manifest if board_path was empty)
- **Follow existing ID conventions** — lowercase prefix, zero-padded 3-digit numbers
- **Inline mode**: if all info is provided via args/flags, write the entry with zero questions
