# refactor-plan

Plan a refactoring approach for existing code.

## Arguments

`$ARGUMENTS` = `--target <file|directory|pattern>` (required)

Optional:
- `--repo <path>` - Target repository
- `--goal <description>` - Refactoring goal

## Process

1. **Analyze Current State**
   - Read target code
   - Identify code smells
   - Map dependencies

2. **Define Goal State**
   - Desired patterns
   - Performance targets
   - Maintainability improvements

3. **Plan Incremental Steps**
   - Break into safe, atomic changes
   - Order by dependency
   - Identify test points

4. **Risk Assessment**
   - Breaking changes
   - Rollback strategy
   - Test coverage gaps

5. **Present Plan**
   - Show step-by-step approach
   - Estimate effort
   - Get approval

## Output

Refactoring plan:
```markdown
# Refactoring Plan: {Target}

## Current State
{Description of current code}

## Goal
{What we want to achieve}

## Steps
1. [ ] Step 1: {Description}
   Files: {files}
   Risk: Low/Medium/High

2. [ ] Step 2: {Description}
   ...

## Test Strategy
- Run existing tests after each step
- Add tests for: {gaps}

## Rollback
If issues arise at step N:
1. Revert commits N through current
2. {Additional steps}

## Estimated Effort
{N} phases, {complexity}
```

## Example

```bash
node dist/index.js refactor-plan --target "src/api" --goal "convert to TypeScript strict mode"

# Output:
# === Refactor Plan: src/api → TypeScript Strict ===
#
# Current state:
#   - 12 files with 'any' types
#   - 3 files with @ts-ignore
#   - 0 strict mode enabled
#
# Steps:
# 1. Add proper types to utility functions (Low risk)
# 2. Type API request/response objects (Medium risk)
# 3. Fix nullable checks (Medium risk)
# 4. Remove @ts-ignore comments (Low risk)
# 5. Enable strict mode (Low risk, after above)
#
# Estimated: 5 phases, medium complexity
#
# [Approve plan? y/n/modify]
```
