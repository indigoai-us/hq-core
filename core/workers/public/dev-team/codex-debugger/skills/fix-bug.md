# fix-bug

Full debugging workflow: diagnose via Codex CLI (read-only), implement fix via Codex CLI (full-auto), and run the complete back-pressure loop.

## Arguments

`$ARGUMENTS` = `--issue <description>` (required)

Optional:
- `--cwd <path>` - Working directory for Codex execution (defaults to target repo)
- `--error-output <text>` - Error output or reproduction steps
- `--files <list>` - Comma-separated list of suspect files to focus on
- `--max-iterations <n>` - Max back-pressure retry iterations (default: 2)
- `--skip-diagnosis` - Skip diagnosis and go straight to fix (use when root cause is already known)

## Process

1. **Parse Inputs**
   - Extract issue description from `--issue`
   - Extract error output from `--error-output` if provided
   - Resolve `--cwd` to absolute path
   - Read suspect files if `--files` provided

2. **Gather Codebase Context**
   - Search target repo for code related to the issue (`qmd vsearch` or Grep)
   - Read affected source files, types, and interfaces
   - Read `package.json` for dependencies and scripts
   - Read `tsconfig.json` for TypeScript configuration
   - Identify test files covering the affected code

3. **Diagnose via Codex** (skip if `--skip-diagnosis`)
   - Run Codex in read-only sandbox for diagnosis:
     ```bash
     cd {cwd} && codex exec --sandbox read-only -c model="gpt-5.4" --reasoning high --fast --cd {cwd} \
       "Diagnose this bug (analysis only, no file changes): {issue_description}. Error: {error_output}. Identify root cause and suggest fix." 2>&1
     ```
   - Parse diagnosis: root cause, affected files, suggested fixes
   - Present diagnosis to human for approval before proceeding

4. **Generate Fix via Codex**
   - Using the diagnosis (or `--issue` if `--skip-diagnosis`), run Codex:
     ```bash
     cd {cwd} && codex exec --full-auto -c model="gpt-5.4" --reasoning high --fast --cd {cwd} \
       "Fix this bug: {root_cause}. Apply the fix: {selected_fix}. Also update or add tests to cover the fix." 2>&1
     ```
   - Codex generates fix and applies it in sandbox

5. **Review Changes**
   - Run `git diff` to capture what Codex changed
   - Present changes to human for review
   - If new test cases were generated, highlight them

6. **Run Back-Pressure**
   - `npm run typecheck` - TypeScript compilation
   - `npm run lint` - Linting rules
   - `npm test` - Test suite (including new tests)
   - If all pass: proceed to step 8
   - If any fail: proceed to step 7

7. **Iterate on Failures** (max `--max-iterations` times)
   - Capture error output from failed checks
   - Feed errors back to Codex:
     ```bash
     cd {cwd} && codex exec --full-auto -c model="gpt-5.4" --reasoning high --fast --cd {cwd} \
       "The previous fix introduced errors: {error_output}. Fix them while preserving the bug fix for: {root_cause}" 2>&1
     ```
   - Re-run back-pressure after each fix attempt
   - If max iterations reached: pause for human intervention

8. **Validate Fix**
   - Confirm original issue is resolved (re-run original failing scenario if reproducible)
   - Check no regressions introduced
   - Show complete diff of all changes
   - Show back-pressure results
   - Get human approval

## Output

Modified files in target repo:
- Patched source files fixing the bug
- New or updated test files covering the fix
- Updated types/interfaces if needed

Response includes:
- `diagnosis`: Root cause explanation (from Codex analysis)
- `fix`: Summary of changes applied
- `filesCreated`: New files (e.g., new tests)
- `filesModified`: Changed files
- `iterations`: Number of back-pressure iterations needed
- `backPressure`: Pass/fail per check (typecheck, lint, test)

## Human Checkpoints

- Approve diagnosis before fix generation begins
- Review proposed fix before it is applied to disk
- Intervene when back-pressure fails after max iterations
- Final approval that the bug is resolved and no regressions exist
