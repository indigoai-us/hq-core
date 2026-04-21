# process-learnings

Process learnings from completed tasks and route to appropriate locations.

## Arguments

`$ARGUMENTS` = `--learnings <json>` (required)

Optional:
- `--project <name>` - Source project
- `--worker <id>` - Source worker
- `--task <id>` - Source task ID

## Learnings Format

```json
{
  "what_worked": ["Description of successful approach"],
  "what_failed": ["Description of failed approach", "Why it failed"],
  "patterns_discovered": ["Reusable pattern description"],
  "context_notes": ["Important context for future reference"],
  "worker_specific": ["Learnings specific to worker type"]
}
```

## Process

1. Parse incoming learnings
2. Categorize each learning:
   - **Project-specific**: Store in `projects/{name}/learnings/`
   - **Worker-specific**: Store in `workers/{worker}/knowledge/`
   - **General pattern**: Store in `knowledge/public/dev-team/patterns/`
   - **Troubleshooting**: Store in `knowledge/public/dev-team/troubleshooting/`
3. Check for duplicates/conflicts with existing knowledge
4. Format as markdown
5. Present to human for approval
6. Write to appropriate location
7. Update related CLAUDE.md files if needed

## Routing Rules

| Category | Destination |
|----------|-------------|
| Project conventions | `projects/{name}/learnings/conventions.md` |
| Bug fixes | `projects/{name}/learnings/bugs-fixed.md` |
| Backend patterns | `knowledge/public/dev-team/patterns/backend/` |
| Frontend patterns | `knowledge/public/dev-team/patterns/frontend/` |
| Database patterns | `knowledge/public/dev-team/patterns/database/` |
| Worker tips | `workers/public/dev-team/{worker}/knowledge/` |
| Error solutions | `knowledge/public/dev-team/troubleshooting/` |

## Output

- Files created/updated
- Summary of knowledge added

## Human Checkpoints

- Approve categorization
- Approve content before writing
- Confirm duplicate handling
