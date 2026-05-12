# report-learnings

Extract and format learnings from task execution.

## Arguments

`$ARGUMENTS` = execution context (from execute skill)

Optional:
- `--verbose` - Include detailed execution trace

## Process

1. **Review Execution**
   - Phases completed
   - Errors encountered
   - Retries needed
   - Time per phase

2. **Extract Learnings**
   Categories:
   - **Pattern**: Reusable code/design pattern discovered
   - **Troubleshoot**: Error/fix that others may encounter
   - **Workflow**: Worker sequence that worked well
   - **Project**: Context specific to this project

3. **Analyze Effectiveness**
   - Did worker sequence work well?
   - Any phases that should be reordered?
   - Context that helped or hurt?

4. **Format Report**
   - Structured JSON for project-manager
   - Human-readable summary

5. **Surface for Approval**
   - Show extracted learnings
   - Human confirms or edits
   - Ready for update-learnings skill

## Learning Extraction Rules

| Signal | Learning Type |
|--------|---------------|
| New code pattern | pattern |
| Error + fix | troubleshoot |
| Sequence worked well | workflow |
| Project-specific context | project |

## Output

Learnings report:
```json
{
  "task": "US-003",
  "project": "auth-feature",
  "execution": {
    "phases": 2,
    "retries": 0,
    "duration": "5m"
  },
  "learnings": [
    {
      "type": "pattern",
      "category": "backend",
      "content": "Session invalidation via Redis DEL command with TTL fallback"
    },
    {
      "type": "workflow",
      "content": "For auth endpoints: backend-dev → qa-tester is sufficient, no architect needed"
    }
  ],
  "recommendations": [
    "Consider adding session tests to smoke-test suite"
  ]
}
```

## Example

```bash
node dist/index.js report-learnings

# Output:
# === Learnings from US-003 ===
#
# Execution summary:
#   - 2 phases completed
#   - 0 retries needed
#   - Duration: 5 minutes
#
# Extracted learnings:
#
# 1. [pattern/backend]
#    Session invalidation via Redis DEL command with TTL fallback
#    Source: backend-dev phase, src/api/auth.ts:45-52
#
# 2. [workflow]
#    For auth endpoints: backend-dev → qa-tester is sufficient
#    Reasoning: No system design needed for simple endpoints
#
# Recommendations:
#   - Consider adding session tests to smoke-test suite
#
# [Approve learnings? y/n/edit]
```
