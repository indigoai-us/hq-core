# implement-feature

Multi-step feature implementation with analysis, generation, and back-pressure loop using Gemini CLI.

## Arguments

`$ARGUMENTS` = `--story <story-id>` (required) `--repo <path>` (required)

Optional:
- `--context <files>` - Additional context files
- `--max-iterations <n>` - Max back-pressure iterations (default: 3)

## Process

1. **Load Story Context**
   - Read story from PRD (acceptance criteria, files, notes)
   - Read existing source files listed in story
   - Analyze dependencies and patterns

2. **Plan Implementation**
   - Break story into implementation steps
   - Identify files to create/modify
   - Map acceptance criteria to concrete code changes

3. **Generate Code via Gemini CLI**
   - For each implementation step:
     ```bash
     cd {repo} && npx @google/gemini-cli --full-auto \
       "Implement: {step_description}. Acceptance criteria: {criteria}. Existing patterns: {pattern_summary}" 2>&1
     ```
   - Capture output and verify files were created/modified

4. **Back-Pressure Loop**
   - Run typecheck, lint, test
   - If failures: feed errors back to Gemini for fix
   - Max iterations controlled by `--max-iterations`
   - On persistent failure: report and escalate

5. **Verify Acceptance Criteria**
   - Check each criterion against generated code
   - Flag any unmet criteria for manual review

## Output

- `summary`: What was implemented
- `filesCreated`: New files
- `filesModified`: Changed files
- `criteriaStatus`: Pass/fail per acceptance criterion
- `backPressure`: Final state of quality gates
