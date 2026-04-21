---
type: reference
domain: [engineering, operations]
status: canonical
tags: [index-md, spec, navigation, directory-map, documentation-standard]
relates_to: []
---

# INDEX.md Specification

Standard for hierarchical INDEX.md files across HQ directories.

## Template

```markdown
# {Directory Name}

> Auto-generated. Updated: {YYYY-MM-DD}

| Name | Description |
|------|-------------|
| `item/` | 1-line description |
```

Optional 1-2 line notes section at bottom for usage hints (e.g., "Load workers via `/run {id}`").

## Description Extraction

| File type | Source |
|-----------|--------|
| `.md` | First `#` heading |
| `.yaml` | `description:` field |
| `.json` | `name` or `description` field |
| Directory | File count + purpose summary |

Max 80 chars per description. If no metadata extractable, use filename.

## Variants

- `projects/INDEX.md` → add `Status` column (active/completed/archived)
- `workspace/orchestrator/INDEX.md` → add `Progress` column (e.g. "5/11 45%")
- `workspace/reports/INDEX.md` → add `Date` column
- `companies/*/INDEX.md` → add `Projects` table (Project/Status/Description) + `Deployments` table (Service/URL/Repo/Platform)

## Locations

### Core (10 directories)

1. `projects/`
2. `companies/{company}/knowledge/`
3. `companies/{company}/knowledge/`
4. `companies/{company}/knowledge/`
5. `knowledge/public/`
6. `workers/public/`
7. `workers/private/`
8. `workspace/orchestrator/`
9. `workspace/reports/`
10. `workspace/social-drafts/`

### Company Root (10 directories)

All `companies/*/INDEX.md` — inventory of settings, data, knowledge + project/deployment relationships.

### Company Knowledge (10 directories)

All `companies/*/knowledge/INDEX.md` — contents of each company's knowledge repo.

Root `INDEX.md` and `workspace/threads/INDEX.md` also exist but follow their own formats.

## Regeneration Rules

- Always full-rewrite (not incremental patch). Idempotent.
- Skip: `INDEX.md` itself, `.DS_Store`, `node_modules/`, dotfiles
- Sort entries: directories first, then files, alphabetical within each group
- Timestamp: use current date in YYYY-MM-DD format

## Update Triggers

| Command | INDEX.md files updated |
|---------|----------------------|
| `/checkpoint` | Root, threads/, + touched company knowledge dirs |
| `/handoff` | Root, threads/, orchestrator/, + touched company knowledge dirs |
| `/reanchor` | Validates freshness, reads indexes for context |
| `/cleanup --reindex` | ALL INDEX.md files (full rebuild) |
| `/plan` | `projects/` |
| `/run-project` | `projects/`, `workspace/orchestrator/` |
| `/newworker` | `workers/public/` or `workers/private/` |
| `/contentidea`, `/suggestposts`, `/post-now` | `workspace/social-drafts/` |
| Report generation | `workspace/reports/` |

## qmd

INDEX.md files are excluded from qmd indexing via `.qmdignore`. They are navigation aids, not searchable content.
