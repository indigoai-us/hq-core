# create-prd

Create new PRD from requirements input.

## Arguments

`$ARGUMENTS` = `--name <name>` (required)

Optional:
- `--input <file>` - Input requirements file (markdown)
- `--template <type>` - Template: feature|bugfix|refactor

## Process

1. Read input requirements (from file or prompt)
2. Extract user stories from requirements
3. Break into epics if multiple areas
4. For each story:
   - Generate acceptance criteria
   - Estimate priority
   - Suggest worker sequence
   - Identify dependencies
5. Present draft PRD to human for review
6. Incorporate feedback
7. Write to `projects/{name}/prd.json`
8. Optionally create beads via `bd init --project {name}`

## Output

PRD JSON file with structure:
```json
{
  "project": "feature-name",
  "created": "2026-01-23",
  "epics": [{
    "id": "E1",
    "title": "Epic Title",
    "stories": [{
      "id": "US-001",
      "title": "Story Title",
      "description": "As a...",
      "acceptance_criteria": [...],
      "priority": 1,
      "passes": false,
      "worker_hints": ["architect", "backend-dev"]
    }]
  }]
}
```

## Example

```bash
node dist/index.js create-prd --name user-auth --input docs/auth-requirements.md

# Output:
# Created PRD with 1 epic, 5 user stories
# - E1: User Authentication (5 stories)
#   - US-001: Login endpoint (priority 1)
#   - US-002: Logout endpoint (priority 1)
#   - US-003: Session management (priority 2)
#   - US-004: Remember me (priority 3)
#   - US-005: Password reset (priority 2)
#
# Review and approve? [y/n/edit]
```
