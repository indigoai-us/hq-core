# apply-best-practices

Run a standard improvement pass with predefined quality goals using Gemini CLI.

## Arguments

`$ARGUMENTS` = `--files <glob-or-list>` (required)

Optional:
- `--cwd <path>` - Working directory / target repo

## Process

1. **Resolve Files**
   - Expand file patterns, verify files exist
   - Read file contents for analysis

2. **Run Standard Goals Pass**
   - Predefined goals: error handling, type safety, null checks, consistent naming, dead code removal, import organization
   ```bash
   cd {cwd} && npx @google/gemini-cli --full-auto \
     "Apply best practices to these files. Goals: proper error handling, type safety, null checks, consistent naming, remove dead code, organize imports. Files: {file_list}" 2>&1
   ```

3. **Capture and Verify**
   - Run `git diff` to capture changes
   - Run back-pressure (typecheck, lint, test)
   - On failure: revert all changes

4. **Present for Approval**
   - Show diffs with rationale
   - This is idempotent — safe to run multiple times

## Output

- `changes`: List of improvements applied
- `diffs`: Before/after per file
- `backPressure`: Quality gate results
