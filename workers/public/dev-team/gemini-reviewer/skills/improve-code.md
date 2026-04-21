# improve-code

Apply targeted code improvements using Gemini CLI with before/after diffs.

## Arguments

`$ARGUMENTS` = `--files <glob-or-list>` (required) `--goals <description>` (required)

Optional:
- `--cwd <path>` - Working directory / target repo

## Process

1. **Resolve Files and Goals**
   - Expand file patterns, read file contents
   - Parse improvement goals (e.g., "error handling, type safety, readability")

2. **Run Gemini CLI for Improvements**
   ```bash
   cd {cwd} && npx @google/gemini-cli --full-auto \
     "Improve these files with goals: {goals}. Files: {file_list}. Show what you changed and why." 2>&1
   ```

3. **Capture Diffs**
   - Run `git diff` to capture before/after changes
   - Present diffs grouped by file

4. **Run Back-Pressure**
   - TypeScript compilation, lint, tests
   - On failure: revert and report (don't iterate — improvements should be clean)

5. **Present for Approval**
   - Show before/after diffs per file
   - Explain rationale for each change
   - Get human approval before finalizing

## Output

- `improvements`: List of changes with rationale
- `diffs`: Before/after per file
- `backPressure`: Quality gate results
