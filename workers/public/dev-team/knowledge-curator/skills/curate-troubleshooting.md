# curate-troubleshooting

Add or update troubleshooting entries for common issues.

## Arguments

`$ARGUMENTS` = `--issue <description>` (required)

Optional:
- `--solution <description>` - Solution that worked
- `--category <category>` - Issue category
- `--tags <tags>` - Comma-separated tags

## Process

1. Search existing troubleshooting for similar issues
2. If exists: update with new information
3. If new: create entry with:
   - Symptoms
   - Root cause
   - Solution
   - Prevention
4. Add relevant tags for searchability
5. Present to human for approval
6. Write to `knowledge/public/dev-team/troubleshooting/`

## Entry Format

```markdown
## Issue: Brief Description

### Symptoms
- What you observe

### Root Cause
Why this happens

### Solution
\`\`\`bash
# Commands or code to fix
\`\`\`

### Prevention
How to avoid this in future

### Tags
`error`, `database`, `timeout`
```

## Categories

- `build` - Build/compile errors
- `runtime` - Runtime errors
- `database` - Database issues
- `network` - Network/API issues
- `auth` - Authentication/authorization
- `deploy` - Deployment issues
- `performance` - Performance problems

## Output

- Troubleshooting entry created/updated
- Summary of changes
