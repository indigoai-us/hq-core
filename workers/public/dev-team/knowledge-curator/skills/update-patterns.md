# update-patterns

Update or create reusable patterns in the knowledge base.

## Arguments

`$ARGUMENTS` = `--category <category>` (required)

Optional:
- `--pattern <name>` - Specific pattern to update
- `--content <markdown>` - Pattern content

## Categories

- `backend` - Backend development patterns
- `frontend` - Frontend development patterns
- `database` - Database patterns
- `infra` - Infrastructure patterns
- `testing` - Testing patterns
- `security` - Security patterns

## Process

1. Read existing patterns in category
2. Identify where new pattern fits:
   - New file
   - Addition to existing file
   - Replacement of outdated pattern
3. Format pattern with:
   - Title
   - When to use
   - Implementation example
   - Caveats/gotchas
4. Present to human for approval
5. Write pattern

## Pattern Format

```markdown
## Pattern Name

### When to Use
- Situation A
- Situation B

### Implementation

\`\`\`typescript
// Example code
\`\`\`

### Caveats
- Important consideration 1
- Important consideration 2

### Related Patterns
- [Other Pattern](link)
```

## Output

- Pattern file created/updated
- Summary of changes
