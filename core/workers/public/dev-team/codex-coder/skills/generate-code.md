# generate-code

Generate code from a task description using the Codex CLI (`codex exec --full-auto`).

## Arguments

`$ARGUMENTS` = `--task <description>` (required)

Optional:
- `--cwd <path>` - Working directory for Codex execution (defaults to target repo)
- `--context <files>` - Comma-separated list of context files to include
- `--output-schema <file>` - JSON schema file for structured output

## Process

1. **Parse Task**
   - Extract task description from `--task`
   - Resolve `--cwd` to absolute path
   - Read context files if provided (max 10 files, max 50KB total)

2. **Analyze Target Repo**
   - Read `package.json` for project type and dependencies
   - Read `tsconfig.json` for TypeScript configuration
   - Identify existing patterns (naming conventions, file structure)

3. **Run Codex Exec for Generation**
   - Build prompt with task description and context:
     ```bash
     cd {cwd} && codex exec --full-auto -c model="gpt-5.4" --reasoning high --fast --cd {cwd} \
       "Generate code for: {task_description}. Follow existing patterns in the repo. Context files: {context_summary}" 2>&1
     ```
   - If `--output-schema` provided, add `--output-schema {file}` flag
   - Codex runs in sandbox with workspace-write access
   - Captures output showing what was created/modified

4. **Collect Results**
   - Run `git status` and `git diff` to identify generated/modified files
   - Read generated files from disk
   - Present to human for review

5. **Run Back-Pressure**
   - `npm run typecheck` - TypeScript compilation
   - `npm run lint` - Linting rules
   - `npm test` - Test suite
   - If any fail: report errors, suggest fixes

6. **Present for Approval**
   - Show generated/modified files with diffs
   - Show back-pressure results
   - Get human approval before finalizing

## Output

Generated files in target repo:
- New source files as specified by task
- Modified existing files (if task required changes)

Response includes:
- `summary`: What was generated
- `filesCreated`: List of new files
- `filesModified`: List of changed files
- `suggestions`: Follow-up improvements

## Human Checkpoints

- Approve task prompt before sending to Codex
- Review generated code before accepting
- Confirm back-pressure results are acceptable
