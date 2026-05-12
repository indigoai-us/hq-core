# learn

Append learnings to project context as workers discover insights.

## Arguments

`$ARGUMENTS` = `--project <name>` (required)

Required (one of):
- `--learning <text>` - Brief description of the learning
- `--from-task <task-id>` - Extract learnings from a completed task

Optional:
- `--category <type>` - Category: pattern, gotcha, tip, question, performance, testing, integration, security (default: inferred)
- `--worker <name>` - Worker who discovered this (default: context-manager)
- `--section <name>` - Target section: patterns, gotchas, tips, questions (default: inferred from category)

## Process

### Add Single Learning

1. Parse the learning input:
   - If `--learning`: Use provided text
   - If `--from-task`: Read task output/notes and extract insights
2. Infer category if not specified:
   - "watch out", "careful", "avoid" → `gotcha`
   - "works well", "effective", "use this" → `pattern`
   - "quick", "shortcut", "hint" → `tip`
   - "why", "how does", "unsure" → `question`
3. Map category to section:
   - `pattern`, `performance` → Patterns
   - `gotcha`, `security` → Gotchas
   - `tip` → Tips
   - `question` → Open Questions
4. Check if learnings.md exists:
   - If not, create from template
   - If exists, read current content
5. Format the learning entry:
   ```markdown
   ### [YYYY-MM-DD] [worker] [task-id]: {Title}

   **Category:** `{category}`

   {Description}
   ```
6. Add to appropriate section
7. Add to index table
8. Update frontmatter dates
9. Write file

### Extract from Task

1. Read task output/summary
2. Identify potential learnings:
   - Unexpected behaviors encountered
   - Solutions that worked
   - Things that didn't work
   - Questions that arose
3. For each learning:
   - Infer category
   - Format entry
   - Add to learnings.md
4. Present extracted learnings to user for approval

## Learning Quality Checklist

Before adding a learning, verify:
- [ ] Specific to this project (not general knowledge)
- [ ] Actionable (tells someone what to do)
- [ ] Not a duplicate of existing learning
- [ ] Has enough context to be useful later

## Input Sources

| Source | Use Case |
|--------|----------|
| Worker output | Automatic extraction after task completion |
| User observation | Manual learning from project experience |
| Bug investigation | Gotchas discovered during debugging |
| Code review | Patterns identified during review |
| Testing | Testing-related insights |

## Output

- Updated `projects/{project}/context/learnings.md`
- If new file: Created from template with first learning

## Integration Points

### Post-Task Hook

Workers can call learn after completing tasks:

```yaml
post_execute:
  - skill: context-manager.learn
    args: --project {project} --from-task {task_id}
```

### Manual Invocation

```bash
/run context-manager learn --project my-project --learning "The cache invalidation must happen before the API call, not after"
```

## Human Checkpoints

- Review inferred category (allow override)
- Approve learning text before writing
- Confirm extracted learnings from task output

## Verification

After completion:
1. Learning added to correct section
2. Index table updated
3. Frontmatter dates updated
4. No duplicate learnings
5. Category tag present
