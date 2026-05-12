# merge-to-staging

Merge approved PR to staging branch.

## Arguments

`$ARGUMENTS` = `--pr <number>` (required)

Optional:
- `--repo <path>` - Target repository

## Process

1. Verify PR is approved
2. Verify all checks pass via `gh pr checks`
3. Detect branch strategy:
   - Check for develop/staging branch
   - Read CONTRIBUTING.md for conventions
4. Merge PR:
   - `gh pr merge --squash` (default)
   - Or `--merge` / `--rebase` per project convention
5. Verify merge succeeded
6. Report status

## Pre-merge Checklist

- [ ] PR is approved by required reviewers
- [ ] All CI checks pass
- [ ] No merge conflicts
- [ ] Branch is up to date with target

## Commands

```bash
# Check PR status
gh pr view <number> --json state,reviews,statusCheckRollup

# Merge with squash
gh pr merge <number> --squash --delete-branch

# Merge with merge commit
gh pr merge <number> --merge --delete-branch
```

## Output

- Merge confirmation
- Commit SHA
- Branch cleanup status

## Human Checkpoints

- Confirm merge before execution
- Handle merge conflicts (escalate to human)
