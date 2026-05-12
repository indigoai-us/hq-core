# next-issue

Select next issue from project PRD/beads to work on.

## Arguments

`$ARGUMENTS` = `--project <name>` (required)

Optional:
- `--filter <label>` - Filter by label/tag
- `--priority <high|medium|low>` - Filter by priority

## Process

1. Load project PRD from `projects/{project}/prd.json`
2. Load beads from project via `bd ls --project {project}`
3. Filter issues where `passes: false`
4. Check dependencies - only issues where all `dependsOn` items pass
5. Score by:
   - Priority field (higher = first)
   - Blocking count (more blockers = first)
   - Complexity estimate (simpler = first for momentum)
6. Present top 3 candidates to human
7. Wait for human selection or approval of recommendation

## Output

Selected issue with:
- Issue ID and title
- Acceptance criteria
- Suggested worker sequence (from `worker_hints` or auto-detected)
- Files likely to be modified
- Dependencies and blockers

## Example

```bash
node dist/index.js next-issue --project auth-feature

# Output:
# Recommended: US-003 "Implement logout endpoint"
# Priority: 1, Blocks: 2 other stories
# Workers: backend-dev → qa-tester
# Files: src/api/auth.ts, src/middleware/session.ts
#
# Alternatives:
# - US-004 "Add remember me checkbox" (Priority: 2)
# - US-005 "Session timeout handling" (Priority: 2)
#
# Proceed with US-003? [y/n/select other]
```
