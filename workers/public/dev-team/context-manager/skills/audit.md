# audit

Check project context for freshness, completeness, and accuracy.

## Arguments

`$ARGUMENTS` = `--project <name>` (required)

Optional:
- `--all` - Audit all projects with context
- `--stale-days <n>` - Days before context is considered stale (default: 30)
- `--fix` - Prompt to fix issues found

## Process

1. Locate project context directory: `projects/{project}/context/`
2. Check completeness:
   - Are all required files present? (overview, architecture, domain)
   - Do files have all required sections per schema?
3. Check freshness:
   - Parse `last_updated` and `last_verified` from frontmatter
   - Flag files older than threshold
   - Check if PRD has changed since last context update
4. Check accuracy signals:
   - Compare architecture.md stack with actual package files
   - Check if referenced files/paths still exist
   - Look for orphaned references
5. Generate audit report
6. If `--fix`, prompt to update stale sections

## Audit Checks

| Check | Description | Severity |
|-------|-------------|----------|
| missing_required | Required context file missing | error |
| missing_sections | Required section missing in file | error |
| stale_content | File not updated in 30+ days | warning |
| unverified_content | File not verified in 30+ days | warning |
| prd_drift | PRD changed since context updated | warning |
| broken_references | Referenced paths don't exist | warning |
| stack_mismatch | architecture.md doesn't match package.json | info |

## Output

Audit report written to: `workspace/context-audits/{project}-{date}.md`

Report format:
```markdown
# Context Audit: {project}
Date: YYYY-MM-DD
Auditor: context-manager

## Summary
- Total files: N
- Errors: N
- Warnings: N
- Coverage: N%

## Issues Found

### Errors
- [ ] overview.md missing required section: Non-Goals

### Warnings
- [ ] architecture.md not verified since YYYY-MM-DD
- [ ] PRD updated YYYY-MM-DD but context last updated YYYY-MM-DD

## Recommendations
1. Update architecture.md to reflect new dependencies
2. Verify domain.md glossary is still accurate
```

## Human Checkpoints

- Review audit findings
- Prioritize which issues to fix
- Approve fix actions

## Verification

After completion:
1. Audit report exists at expected path
2. Report includes all severity levels checked
3. No false positives (referenced files actually exist when marked as broken)
