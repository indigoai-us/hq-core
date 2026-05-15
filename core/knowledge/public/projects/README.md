# Projects

Guidelines for creating and tracking projects in HQ.

## When to Create a Project

Create a `personal/projects/{name}/` folder for personal/HQ work, or `companies/{co}/projects/{name}/` for company-owned work, when:
- Work spans multiple steps or sessions
- There are tangible deliverables (code, content, launches)
- You'd want to reference the work later

**Do not create** for:
- One-off questions or research
- Quick fixes (< 30 min)
- Pure conversation without deliverables

## Project Structure

```
personal/projects/{name}/
├── README.md      # Required - overview, status, log
├── prd.json       # Required for multi-feature projects
└── CLAUDE.md      # Optional - project-specific rules
```

## README.md (Required)

Use the template at `core/knowledge/public/projects/templates/README.template.md`.

Key sections:
- **Overview**: 1-2 sentences
- **Status**: Phase + repo link
- **Deliverables**: Checklist of what's being built
- **Log**: Date/action/outcome table updated as work progresses

## prd.json (Required for Multi-Feature)

```json
{
  "project": "project-name",
  "goal": "what it achieves",
  "success_criteria": "how to know it's done",
  "repo": "repos/private/{name}/",
  "features": [
    {"id": "F1", "title": "Feature name", "passes": false}
  ]
}
```

## Linking to Repos

If project has code:
- Repo goes in `repos/private/{name}/` or `repos/public/{name}/`
- README.md references: `**Repo**: repos/private/{name}/`

## Session Protocol

1. **Start of session**: Create `personal/projects/{name}/README.md` or `companies/{co}/projects/{name}/README.md` if new project
2. **During session**: Update log table after major milestones
3. **End of session**: Ensure README reflects current state

## Examples

Good project folders:
- `personal/projects/sol-reader/` - iPad app
- `companies/{co}/projects/{company}-capital/` - Token launch
- `companies/{co}/projects/{company}-site/` - Website migration

Not projects (too small):
- Fix a typo in docs
- Answer a question about code
- Run a one-time report
