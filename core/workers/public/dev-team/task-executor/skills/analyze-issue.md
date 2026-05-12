# analyze-issue

Analyze issue to determine required workers and execution sequence.

## Arguments

`$ARGUMENTS` = `--issue <id> --project <name>` (required)

Optional:
- `--repo <path>` - Target repository for file analysis

## Process

1. **Load Issue**
   - Read from PRD or beads
   - Parse title, description, acceptance criteria

2. **Check Worker Hints**
   - If `worker_hints` field exists, use as base
   - Validate hints are valid worker IDs

3. **Auto-Detect Workers**
   If no hints, analyze based on:
   - Keywords in title/description
   - File patterns in acceptance criteria
   - Project type (frontend/backend/fullstack)

4. **Determine Sequence**
   Standard sequences:
   - architect always first (if system design needed)
   - database-dev before backend-dev (if schema changes)
   - backend-dev before frontend-dev (if API needed)
   - qa-tester always last
   - code-reviewer after all dev workers

5. **Estimate Scope**
   - Files likely to be modified
   - Complexity score (simple/medium/complex)
   - Estimated phases

6. **Present Analysis**
   - Show worker sequence
   - Show reasoning
   - Ask for confirmation

## Worker Detection Rules

| Pattern | Workers |
|---------|---------|
| "API", "endpoint", "route" | backend-dev |
| "database", "schema", "migration" | database-dev |
| "component", "UI", "page" | frontend-dev |
| "animation", "transition", "polish" | motion-designer |
| "CI/CD", "deploy", "pipeline" | infra-dev |
| "test", "coverage", "accessibility" | qa-tester |
| "architecture", "design", "refactor" | architect |

## Output

Analysis report:
```json
{
  "issue": "US-003",
  "title": "Implement logout endpoint",
  "workers": ["backend-dev", "qa-tester"],
  "sequence": [
    {"worker": "backend-dev", "phase": "Create logout API endpoint"},
    {"worker": "qa-tester", "phase": "Verify logout functionality"}
  ],
  "estimated_files": ["src/api/auth.ts", "src/middleware/session.ts"],
  "complexity": "simple",
  "reasoning": "Detected 'endpoint' keyword, no frontend changes mentioned"
}
```

## Example

```bash
node dist/index.js analyze-issue --issue US-003 --project auth-feature

# Output:
# === Analysis: US-003 ===
#
# Title: Implement logout endpoint
#
# Detected patterns:
#   - "endpoint" → backend-dev
#   - No UI changes → skip frontend-dev
#
# Recommended sequence:
#   1. backend-dev: Create logout API endpoint
#   2. qa-tester: Verify logout functionality
#
# Estimated files:
#   - src/api/auth.ts
#   - src/middleware/session.ts
#
# Complexity: simple (2 phases, ~2 files)
#
# [Confirm sequence? y/n/modify]
```
