# project-status

Show project progress, blockers, and next steps.

## Arguments

`$ARGUMENTS` = `--project <name>` (required)

Optional:
- `--verbose` - Show detailed story status
- `--format <table|json|markdown>` - Output format

## Process

1. Load PRD from `projects/{project}/prd.json`
2. Load beads status via `bd ls --project {project}`
3. Calculate metrics:
   - Total stories, completed, in-progress, blocked
   - Completion percentage
   - Blockers (failed stories, unmet dependencies)
4. Identify:
   - What's blocking progress
   - Next recommended action
   - Estimated remaining work
5. Present status summary

## Output

Status report with:
- Progress bar and percentage
- Story breakdown by status
- Blockers and recommendations
- Next steps

## Example

```bash
node dist/index.js project-status --project auth-feature

# Output:
# === auth-feature ===
# Progress: ████████░░ 80% (4/5 stories)
#
# ✅ Completed (4):
#   - US-001: Login endpoint
#   - US-002: Logout endpoint
#   - US-003: Session management
#   - US-005: Password reset
#
# 🔄 In Progress (0)
#
# ❌ Pending (1):
#   - US-004: Remember me (blocked by: none)
#
# 🚧 Blockers: None
#
# Next: Run task-executor on US-004
# Estimated: 1 more iteration
```
