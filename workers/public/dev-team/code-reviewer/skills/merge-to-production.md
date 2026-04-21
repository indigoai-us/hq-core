# merge-to-production

Merge staging to production branch.

## Arguments

`$ARGUMENTS` = `--repo <path>` (required)

Optional:
- `--tag <version>` - Version tag to create
- `--skip-checks` - Skip pre-merge checks (NOT RECOMMENDED)

## Process

1. Verify staging is stable:
   - All tests pass
   - No pending hotfixes
   - Staging environment healthy
2. Create release PR (staging → main/production)
3. Run final checks:
   - Security scan
   - Performance regression check
   - Breaking change detection
4. Present to human for approval
5. Merge with merge commit (preserve history)
6. Create version tag (if specified)
7. Trigger production deploy (if configured)

## Pre-production Checklist

- [ ] Staging has been validated
- [ ] No breaking changes without migration
- [ ] Database migrations are backward compatible
- [ ] Feature flags configured correctly
- [ ] Rollback plan documented

## Commands

```bash
# Create release PR
gh pr create --base main --head staging --title "Release v1.x.x"

# Merge to production
gh pr merge <number> --merge

# Create tag
git tag -a v1.x.x -m "Release v1.x.x"
git push origin v1.x.x
```

## Output

- Production merge confirmation
- Version tag (if created)
- Deploy trigger status

## Human Checkpoints

- **ALWAYS** require human approval before production merge
- Review breaking changes
- Confirm rollback plan exists
