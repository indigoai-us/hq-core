# improve-code

Apply targeted improvements to code files using the Codex CLI (`codex exec --full-auto`). Shows before/after diffs for human approval.

## Arguments

`$ARGUMENTS` = `--files <glob-or-list>` (required, e.g., "src/services/billing.ts" or "src/api/*.ts")

Required:
- `--goals <list>` - Comma-separated improvement goals (e.g., "error handling, type safety, readability")

Optional:
- `--cwd <path>` - Working directory / target repo

## Process

1. **Resolve Files**
   - Expand glob patterns in `--files` to concrete file list
   - Verify each file exists; skip missing files with warning
   - Read files to capture "before" state for diffing
   - Cap at 10 files per improvement run (warn if exceeded)

2. **Parse Goals**
   - Split `--goals` into individual improvement objectives
   - Validate goals are actionable (not vague like "make better")
   - Examples of valid goals:
     - "error handling" - Add try/catch, error types, recovery logic
     - "type safety" - Replace `any`, add generics, narrow unions
     - "performance" - Memoize, reduce re-renders, optimize queries
     - "readability" - Extract functions, improve naming, add JSDoc
     - "test coverage" - Add missing test cases, edge cases
     - "security" - Input validation, sanitization, auth checks

3. **Run Codex Exec for Improvements**
   - Build prompt with file list and goals:
     ```bash
     cd {cwd} && codex exec --full-auto -c model="gpt-5.4" --reasoning high --fast --cd {cwd} \
       "Improve these files: {file_list}. Goals: {goals}. Make targeted changes only — do not refactor unrelated code. Show what you changed." 2>&1
     ```
   - Codex runs in sandbox with workspace-write access
   - Captures output showing what was modified

4. **Collect and Diff Results**
   - Run `git diff` to capture actual file changes
   - For each modified file, generate before/after comparison
   - Summarize changes per goal

5. **Present Before/After**
   - Show each improvement with context:
     ```
     ## Improvements Applied

     ### src/services/billing.ts
     **Goal: error handling**
     Added try/catch around Stripe API calls with typed error recovery

     ```diff
     - const charge = await stripe.charges.create(params);
     + let charge: Stripe.Charge;
     + try {
     +   charge = await stripe.charges.create(params);
     + } catch (err) {
     +   if (err instanceof Stripe.errors.StripeCardError) {
     +     throw new BillingError('card_declined', err.message);
     +   }
     +   throw new BillingError('charge_failed', 'Unexpected error');
     + }
     ```
     ```

6. **Run Back-Pressure** (after human approval)
   - `npm run typecheck` - TypeScript compilation
   - `npm run lint` - Linting rules
   - `npm test` - Test suite
   - If any fail: revert changes (`git checkout -- {files}`), report errors, do NOT iterate automatically
   - If all pass: confirm improvements applied successfully

## Output

Improved files in target repo (after approval):
- Modified source files with targeted improvements
- No new files created (improve-code only modifies existing files)

Response includes:
- `summary`: What was improved across all files
- `improvements`: Description of changes per file/goal
- `filesModified`: List of changed files
- `goalsAddressed`: Which goals were successfully applied

## Human Checkpoints

- Review before/after diffs before accepting changes
- Approve back-pressure results after improvements applied
- Decide whether to keep or revert if back-pressure fails
