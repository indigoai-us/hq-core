# update

Update specific context files with new information.

## Arguments

`$ARGUMENTS` = `--project <name>` (required) `--file <context-file>` (required)

Context files: overview, architecture, domain, decisions, stakeholders, learnings

Optional:
- `--section <name>` - Update only a specific section
- `--from-source <path>` - Extract updates from a source file
- `--add-decision` - Add a new ADR to decisions.md
- `--verify-only` - Only update verification date, not content

## Process

### Standard Update

1. Read existing context file
2. Gather new information:
   - From user input
   - From source file if specified
   - From repo analysis if relevant
3. Merge with existing content:
   - Preserve existing structure
   - Highlight what's new vs changed
   - Maintain attribution
4. Update frontmatter:
   - Set `last_updated` to today
   - Set `last_verified` to today
   - Set `verified_by` to context-manager
5. Present diff to user for approval
6. Write updated file

### Add Decision (ADR)

1. Gather decision information:
   - Title
   - Context: What's the issue?
   - Decision: What did we decide?
   - Consequences: What are the tradeoffs?
2. Assign next ADR number
3. Add to decisions.md index
4. Create decision entry with format:
```markdown
## ADR-{N}: {Title}
**Date:** YYYY-MM-DD
**Status:** Accepted|Deprecated|Superseded

### Context
{Why this decision was needed}

### Decision
{What we decided}

### Consequences
{What follows from this decision}
```

### Verify Only

1. Read existing context file
2. Confirm content is still accurate with user
3. Update `last_verified` date only
4. Preserve `last_updated` date

## Input Sources

| Source | Use Case |
|--------|----------|
| User input | Direct updates, clarifications |
| PRD changes | Goals, non-goals updates |
| Code changes | Architecture, stack updates |
| Meeting notes | Decisions, stakeholders |
| Slack/Discord | Domain terms, concepts |

## Output

- Updated context file at `projects/{project}/context/{file}.md`
- Backup of previous version (if significant changes)

## Human Checkpoints

- Review proposed changes before writing
- Confirm accuracy of merged content
- Approve any inferred updates

## Verification

After completion:
1. File has updated frontmatter dates
2. All required sections still present
3. No content was accidentally removed
4. Schema validation passes if context.yaml exists
