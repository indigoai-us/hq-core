# execute

Execute issue end-to-end: analyze, spawn workers, validate, report learnings.

## Arguments

`$ARGUMENTS` = `--issue <id> --project <name>` (required)

Optional:
- `--repo <path>` - Target repository path
- `--skip-validation` - Skip back pressure checks (not recommended)

## Process

1. **Load Issue**
   - Read issue from PRD or beads
   - Validate issue exists and is not already passing

2. **Analyze & Plan**
   - Determine required workers (from hints or auto-detect)
   - Order workers by dependency
   - Estimate scope and files affected
   - Present plan to human for approval

3. **For Each Worker Phase**
   ```
   a. BEFORE: Show "Spawning {worker} for {description}"
      → Wait for human: approve / inject context / skip

   b. EXECUTE: Spawn worker via Claude Task tool
      - Pass focused context (issue spec + relevant files)
      - Worker executes with its own context isolation

   c. AFTER: Show results
      - Files changed
      - Test results
      - Any warnings or notes
      → Wait for human: approve / request changes / rollback

   d. VALIDATE: Run back pressure checks
      - npm run typecheck
      - npm run lint
      - npm run test (if applicable)
      → If fail: surface error, offer retry or fix

   e. COMMIT: Create commit for this phase
      → Human approves commit message
   ```

4. **On Completion**
   - Mark issue as passing in PRD/beads
   - Extract learnings from execution
   - Format learnings report
   - Return to project-manager

5. **On Failure**
   - Log failure point and error
   - Offer options: retry / rollback / escalate
   - Never auto-proceed on ambiguity

## Worker Spawn Pattern

Using Claude Code's Task tool:
```typescript
// Spawn a worker as subagent
Task({
  description: "Backend dev: implement API endpoint",
  prompt: `
    Execute backend-dev worker for issue ${issueId}

    Context:
    - Issue: ${issue.title}
    - Acceptance criteria: ${issue.acceptance_criteria}
    - Files to modify: ${files.join(', ')}

    Instructions:
    1. Read the target files
    2. Implement the required changes
    3. Run typecheck and lint
    4. Report completion with changes made
  `,
  subagent_type: "general-purpose"
})
```

## Output

Execution report with:
- Issue status (pass/fail)
- Phases completed
- Files changed
- Validation results
- Learnings extracted
- Commit hashes

## Example

```bash
node dist/index.js execute --issue US-003 --project auth-feature --repo repos/private/my-app

# Output:
# === Executing US-003: Implement logout endpoint ===
#
# Planned phases:
# 1. backend-dev: Create logout API endpoint
# 2. qa-tester: Verify logout functionality
#
# [Approve plan? y/n]
# > y
#
# Phase 1: Spawning backend-dev...
# [Approve? y/inject/skip]
# > y
#
# backend-dev completed:
#   Changed: src/api/auth.ts (+25 lines)
#   Tests: 3 passing
#
# [Approve changes? y/n/rollback]
# > y
#
# Validation:
#   ✅ typecheck passed
#   ✅ lint passed
#   ✅ tests passed
#
# Phase 2: Spawning qa-tester...
# ...
#
# === Issue US-003 Complete ===
# Learnings:
#   - [pattern] Session invalidation via Redis DEL command
```
