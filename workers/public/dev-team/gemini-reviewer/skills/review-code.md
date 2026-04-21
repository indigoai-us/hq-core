# review-code

Review code files for quality issues using Gemini CLI. Outputs severity-grouped findings with actionable suggestions.

## Arguments

`$ARGUMENTS` = `--files <glob-or-list>` (required)

Optional:
- `--focus <area>` - Review focus: `security` | `performance` | `style` | `correctness` | `all` (default: `all`)
- `--cwd <path>` - Working directory / target repo

## Process

1. **Resolve Files**
   - Expand glob patterns in `--files` to concrete file list
   - Verify each file exists; skip missing files with warning
   - Cap at 20 files per review

2. **Determine Focus Area**
   - `security`: injection, auth bypass, secret exposure, SSRF, XSS
   - `performance`: N+1 queries, memory leaks, unnecessary re-renders
   - `style`: naming conventions, code organization, pattern consistency
   - `correctness`: logic errors, edge cases, null handling, race conditions
   - `all`: balanced review across all categories

3. **Run Gemini CLI for Review**
   ```bash
   cd {cwd} && npx @google/gemini-cli --full-auto \
     "Review these files for {focus_area} issues. Files: {file_list}. Group findings by severity: critical, high, medium, low, info. Include file path and line numbers." 2>&1
   ```

4. **Parse and Group Results**
   - Group by severity: `critical` > `high` > `medium` > `low` > `info`
   - Within each severity, sort by file path then line number

5. **Format Output**
   ```
   ## Review Summary
   Files Reviewed: N
   Issues Found: N (breakdown by severity)

   ### Critical
   - file:line [category] description + suggested fix
   ...
   ```

## Output

- `issues`: Findings grouped by severity
- `summary`: Narrative summary
- `counts`: Issues per severity level
