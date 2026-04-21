# request-changes

Request changes on a pull request with actionable feedback.

## Arguments

`$ARGUMENTS` = `--pr <number>` (required)

Optional:
- `--repo <path>` - Target repository
- `--blocking` - Mark as blocking review

## Process

1. Fetch current review state
2. Formulate change requests:
   - Specific, actionable items
   - Reference line numbers
   - Suggest concrete fixes
3. Categorize issues:
   - Must fix (blocking)
   - Should fix (non-blocking)
   - Consider (optional)
4. Present to human for approval
5. Submit review via `gh pr review`

## Change Request Format

```markdown
### Must Fix
- [ ] **Line 42**: SQL injection vulnerability - use parameterized query
- [ ] **Line 87**: Missing null check before accessing `.length`

### Should Fix
- [ ] **Line 23**: Consider extracting to helper function for reuse
- [ ] **Line 56**: Magic number - extract to named constant

### Consider
- [ ] **Line 12**: Could use optional chaining for cleaner code
```

## Commands

```bash
# Submit review requesting changes
gh pr review <number> --request-changes --body "Review comments..."

# Add line comment
gh pr comment <number> --body "Comment text"
```

## Best Practices

- Be specific, not vague
- Explain why, not just what
- Offer solutions, not just problems
- Be respectful and constructive
- Acknowledge good work too

## Human Checkpoints

- Approve review content before submission
- Confirm blocking vs non-blocking classification
