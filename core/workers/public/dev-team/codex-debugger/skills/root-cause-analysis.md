# root-cause-analysis

Analyze an issue using the Codex CLI in read-only mode. Returns a diagnosis without making any file changes.

## Arguments

`$ARGUMENTS` = `--issue <description>` (required)

Optional:
- `--cwd <path>` - Working directory for Codex execution (defaults to target repo)
- `--error-output <text>` - Error output to include in analysis (if available)
- `--files <list>` - Comma-separated list of suspect files to focus on
- `--depth <level>` - Analysis depth: `shallow` | `standard` | `deep` (default: standard)

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
   - Map dependency chain of affected modules

3. **Run Codex in Read-Only Mode**
   - Run Codex with read-only sandbox (no file modifications):
     ```bash
     cd {cwd} && codex exec --sandbox read-only -c model="gpt-5.4" --reasoning high --fast --cd {cwd} \
       "Root cause analysis only — do NOT modify any files. Issue: {issue_description}. Error output: {error_output}. Analyze: root cause, contributing factors, affected files with line numbers, execution path, and suggest fixes ranked by risk." 2>&1
     ```
   - **No file changes are made** — sandbox enforces read-only

4. **Structure Diagnosis**
   - Parse Codex output into structured findings:
     - **Root Cause**: Primary cause of the issue
     - **Contributing Factors**: Secondary issues that amplify the problem
     - **Affected Files**: Files involved in the issue with specific lines
     - **Call Chain**: Execution path leading to the error
     - **Suggested Fixes**: Ranked list of proposed solutions (not applied)
     - **Risk Assessment**: Impact of each suggested fix

5. **Present Diagnosis**
   - Show structured diagnosis to human
   - Include code snippets from affected areas
   - Recommend next steps: manual fix, debug-issue, or fix-bug skill

## Output

No file changes. Analysis-only output.

Response includes:
- `rootCause`: Primary cause identification
- `contributingFactors`: Secondary issues
- `affectedFiles`: List of files with specific line references
- `callChain`: Execution path trace
- `suggestedFixes`: Ranked list of proposed solutions with risk levels
- `riskAssessment`: Impact analysis per suggested fix
- `recommendedSkill`: Which codex-debugger skill to use next (debug-issue or fix-bug)

## Human Checkpoints

- Review diagnosis for accuracy before acting on it
- Decide which suggested fix to pursue (or propose an alternative)
- Choose whether to proceed with debug-issue, fix-bug, or manual fix
