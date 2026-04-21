# update-learnings

Route learnings from completed tasks to appropriate knowledge locations.

## Arguments

`$ARGUMENTS` = learning report from task-executor (JSON or structured text)

Optional:
- `--project <name>` - Project context
- `--dry-run` - Show routing without writing

## Process

1. Parse learning report
2. Categorize each learning:
   - **project-specific**: Unique to this project context
   - **pattern**: Reusable code/design pattern
   - **troubleshooting**: Error/fix that others may encounter
   - **workflow**: Worker sequence that worked well
3. Route to appropriate location:
   - Project-specific → `projects/{name}/learnings/`
   - Pattern → `knowledge/public/dev-team/patterns/{category}/`
   - Troubleshooting → `knowledge/public/dev-team/troubleshooting/`
   - Workflow → `knowledge/public/dev-team/workflows/`
4. Format as markdown with standard template
5. Present routing plan to human
6. Write files after approval
7. Update relevant CLAUDE.md if patterns affect guidance

## Learning Categories

| Category | Location | Example |
|----------|----------|---------|
| project | projects/{name}/learnings/ | "API uses custom auth header X-Token" |
| pattern | knowledge/public/dev-team/patterns/ | "Retry pattern for flaky external APIs" |
| troubleshoot | knowledge/public/dev-team/troubleshooting/ | "ESLint fails on CI but not local" |
| workflow | knowledge/public/dev-team/workflows/ | "For DB-heavy: database-dev before architect" |

## Output

- Markdown files written to knowledge locations
- Summary of what was written where

## Example

```bash
node dist/index.js update-learnings --project auth-feature

# Input (from task-executor):
# {
#   "task": "US-003",
#   "learnings": [
#     {"type": "pattern", "content": "Session tokens use JWT with 15m expiry"},
#     {"type": "troubleshoot", "content": "Redis connection must be established before auth middleware"}
#   ]
# }

# Output:
# Routing learnings:
# - [pattern] → knowledge/public/dev-team/patterns/backend/jwt-session-tokens.md
# - [troubleshoot] → knowledge/public/dev-team/troubleshooting/redis-auth-order.md
#
# Approve routing? [y/n/edit]
```
