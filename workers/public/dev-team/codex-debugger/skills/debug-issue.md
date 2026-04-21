# debug-issue

Diagnose an issue from error output using the Codex CLI (`codex exec --full-auto`), apply the fix, and run back-pressure checks.

## Arguments

`$ARGUMENTS` = `--issue <description>` (required) + `--error-output <text>` (required)

Optional:
- `--cwd <path>` - Working directory for Codex execution (defaults to target repo)
- `--files <list>` - Comma-separated list of suspect files to focus on
- `--max-iterations <n>` - Max back-pressure retry iterations (default: 2)

## Process

1. **Parse Inputs**
   - Extract issue description from `--issue`
   - Extract error output from `--error-output`
   - Resolve `--cwd` to absolute path
   - Read suspect files if `--files` provided

2. **Analyze Error Context**
   - Parse error output for: file paths, line numbers, error codes, stack traces
   - Read affected source files from disk
   - Read `package.json` and `tsconfig.json` for project configuration
   - Identify error class: type error, runtime error, lint violation, test failure

3. **Run Codex to Diagnose and Fix**
   - Run Codex with full error context:
     ```bash
     cd {cwd} && codex exec --full-auto -c model="gpt-5.4" --reasoning high --fast --cd {cwd} \
       "Diagnose and fix this issue: {issue_description}. Error output: {error_output}. Suspect files: {file_list}. Apply the fix directly." 2>&1
     ```
   - Codex runs in sandbox, reads code, diagnoses issue, and applies fix

4. **Review Changes**
   - Run `git diff` to capture what Codex changed
   - Parse the Codex output for diagnosis and root cause explanation
   - Present diagnosis and changes to human for review

5. **Run Back-Pressure**
   - `npm run typecheck` - TypeScript compilation
   - `npm run lint` - Linting rules
   - `npm test` - Test suite
   - If all pass: proceed to step 7
   - If any fail: proceed to step 6

6. **Iterate on Failures** (max `--max-iterations` times)
   - Capture new error output from failed checks
   - Feed errors back to Codex:
     ```bash
     cd {cwd} && codex exec --full-auto -c model="gpt-5.4" --reasoning high --fast --cd {cwd} \
       "Fix attempt introduced new errors: {new_error_output}. Previous issue: {issue_description}. Fix while preserving the original fix." 2>&1
     ```
   - Re-run back-pressure after each fix attempt
   - If max iterations reached: pause for human intervention

7. **Report Results**
   - Show diagnosis summary
   - Show all file changes with diffs
   - Show back-pressure results (pass/fail per check)
   - Show iteration count

## Output

Modified files in target repo:
- Patched source files addressing the diagnosed issue
- Updated tests if the fix required test changes

Response includes:
- `diagnosis`: Root cause explanation
- `filesModified`: List of changed files
- `iterations`: Number of back-pressure iterations needed
- `backPressure`: Pass/fail per check (typecheck, lint, test)

## Human Checkpoints

- Review diagnosis before fix is applied
- Approve file changes when fix touches more than 2 files
- Intervene when back-pressure fails after max iterations
- Confirm fix addresses the original issue (not just symptoms)
