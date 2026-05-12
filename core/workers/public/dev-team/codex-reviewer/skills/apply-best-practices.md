# apply-best-practices

Run a standard improvement pass with predefined quality goals using the Codex CLI (`codex exec --full-auto`). Consistent code quality improvements.

## Arguments

`$ARGUMENTS` = `--files <glob-or-list>` (required, e.g., "src/**/*.ts" or "src/api/routes/*.ts")

Optional:
- `--cwd <path>` - Working directory / target repo
- `--skip <goals>` - Comma-separated goals to skip (e.g., "performance,readability")
- `--only <goals>` - Comma-separated goals to run exclusively (overrides default set)

## Process

1. **Resolve Files**
   - Expand glob patterns in `--files` to concrete file list
   - Verify each file exists; skip missing files with warning
   - Read files to capture "before" state
   - Cap at 10 files per run (warn if exceeded)

2. **Determine Goals**
   - Default predefined goals (applied in order):
     1. **Error handling** - Add try/catch, typed errors, recovery logic, avoid swallowed exceptions
     2. **Type safety** - Replace `any` with proper types, add generics, narrow union types, use strict null checks
     3. **Performance** - Memoize expensive computations, avoid unnecessary re-renders, optimize loops, reduce allocations
     4. **Readability** - Extract complex logic into named functions, improve variable naming, add JSDoc for public APIs, remove dead code
   - If `--skip` provided: remove listed goals from default set
   - If `--only` provided: use only the listed goals (must be from predefined set)
   - Validate at least one goal remains

3. **Run Codex Exec with Goals**
   - For each goal, run Codex in sequence (sequential ensures no conflicts):
     ```bash
     cd {cwd} && codex exec --full-auto -c model="gpt-5.4" --reasoning high --fast --cd {cwd} \
       "Apply {goal} best practices to: {file_list}. Make minimal, targeted changes. Do not modify unrelated code." 2>&1
     ```
   - After each goal pass, verify files are still valid (quick syntax check)
   - If a goal pass breaks compilation, revert that goal and continue to next

4. **Aggregate Results**
   - Run `git diff` to capture all changes (before first pass vs. after last pass)
   - Summarize per-goal:
     ```
     ## Best Practices Applied

     ### Error Handling (3 improvements)
     - src/api/auth.ts: Added typed catch blocks for JWT verification
     - src/services/billing.ts: Added error recovery for Stripe webhook failures
     - src/lib/db.ts: Added connection error handling with retry

     ### Type Safety (5 improvements)
     - src/api/auth.ts: Replaced `any` with `JWTPayload` interface
     ...

     ### Performance (1 improvement)
     - src/services/analytics.ts: Memoized expensive aggregation query

     ### Readability (2 improvements)
     - src/api/auth.ts: Extracted token validation to `validateBearerToken()`
     - src/lib/db.ts: Added JSDoc for public connection methods
     ```

5. **Run Back-Pressure**
   - `npm run typecheck` - TypeScript compilation
   - `npm run lint` - Linting rules
   - `npm test` - Test suite
   - If any fail: revert ALL changes (atomic — either all goals apply or none), report errors
   - If all pass: confirm best practices applied successfully

6. **Present for Approval**
   - Show per-goal summary with improvement counts
   - Show complete unified diff
   - Show back-pressure results
   - Get human approval before finalizing

## Output

Improved files in target repo (after approval):
- Modified source files with best-practice improvements
- No new files created

Response includes:
- `summary`: Overall improvement summary
- `goalsApplied`: Array of goals with improvement counts
- `improvements`: Description per file and goal
- `filesModified`: List of all changed files
- `totalImprovements`: Count of all changes made

## Human Checkpoints

- Review predefined goals before execution (confirm skip/only selections)
- Review per-goal improvements before accepting
- Approve back-pressure results
- Decide whether to keep or revert if back-pressure fails
