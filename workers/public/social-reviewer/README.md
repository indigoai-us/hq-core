# social-reviewer

Quality gate worker for the social-team. Reviews drafts and controls the approval gate.

## Skills

| Skill | What it does |
|-------|-------------|
| `review` | Review a single draft against the safety checklist |
| `review-batch` | Review all pending drafts in a profile's queue |
| `promote` | Advance a draft to "approved" (requires human confirmation) |
| `reject` | Reject a draft with specific feedback |

## Usage

```bash
/run social-reviewer review post-035 --profile {company}
/run social-reviewer review-batch --profile personal
/run social-reviewer promote post-035 --profile {company}
/run social-reviewer reject post-035 --reason "contains AI slop language"
```

## Review Checklist

### BLOCK (fails = rejected)
1. No markdown metadata in content body
2. Not a test/placeholder message
3. Within platform character limits
4. Company isolation respected
5. Referenced images exist

### WARN (flagged but not blocked)
6. AI-typical language patterns
7. Voice/tone alignment
8. Duplicate content detection
