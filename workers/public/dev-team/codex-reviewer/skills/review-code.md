# review-code

Review code files for quality issues using the Codex CLI (`codex review`). Outputs severity-grouped findings with actionable suggestions.

## Arguments

`$ARGUMENTS` = `--files <glob-or-list>` (required, e.g., "src/auth/*.ts" or "src/api/handler.ts,src/lib/db.ts")

Optional:
- `--focus <area>` - Review focus: `security` | `performance` | `style` | `correctness` | `all` (default: `all`)
- `--cwd <path>` - Working directory / target repo

## Process

1. **Resolve Files**
   - Expand glob patterns in `--files` to concrete file list
   - Verify each file exists; skip missing files with warning
   - Read files to confirm they are non-empty source files
   - Cap at 20 files per review (warn if exceeded, review first 20)

2. **Determine Focus Area**
   - If `--focus` provided, use directly
   - Default: `all` (reviews across all categories)
   - Focus areas map to review priorities:
     - `security`: injection, auth bypass, secret exposure, SSRF, XSS
     - `performance`: N+1 queries, memory leaks, unnecessary re-renders, O(n^2) loops
     - `style`: naming conventions, code organization, pattern consistency, dead code
     - `correctness`: logic errors, edge cases, null handling, race conditions
     - `all`: balanced review across all categories

3. **Run Codex Review via CLI**
   - Determine review scope based on context:
     - If reviewing uncommitted changes: `codex review --uncommitted`
     - If reviewing a specific commit: `codex review --commit <sha>`
     - If reviewing against a branch: `codex review --base <branch>`
     - Default (standalone invocation): `codex review --uncommitted`
   - Add custom focus as prompt argument:
     ```bash
     cd {cwd} && codex review --uncommitted -c model="gpt-5.4" --reasoning high --fast \
       "Focus on {focus_area}. Review files: {file_list}. Flag issues by severity: critical, high, medium, low, info." 2>&1
     ```
   - Capture full output (markdown-formatted review)

4. **Parse and Group Results**
   - Parse Codex CLI output (markdown format with issue descriptions)
   - Extract issues and group by severity: `critical` > `high` > `medium` > `low` > `info`
   - Within each severity, sort by file path then line number
   - Count totals per severity level

5. **Format Output**
   - Present severity-grouped findings:
     ```
     ## Review Summary
     Overall Score: 7/10
     Files Reviewed: 5
     Issues Found: 12 (2 critical, 3 high, 4 medium, 2 low, 1 info)

     ### Critical (2)
     - src/auth/login.ts:45 [security] SQL injection in user lookup
       Suggested fix: Use parameterized query instead of string interpolation

     ### High (3)
     ...
     ```

6. **Present for Decision**
   - Show grouped findings
   - Offer options: accept findings, address critical/high issues, dismiss

## Output

Review report with:
- `issues`: Findings grouped by severity
- `summary`: Narrative summary of review
- `counts`: Issues per severity level
- `reviewScope`: What was reviewed (uncommitted/commit/branch)

## Human Checkpoints

- Review findings before taking action
- Decide which issues to address vs. accept as-is
- Approve if running improve-code as follow-up
