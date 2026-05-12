# Final Gate

Final production certification check. Run AFTER qa-tester has passed.

## Trigger

Called by `/execute-task` after qa-tester reports PASS, before marking story as done.

## Inputs

- `target_repo`: Path to the repo being tested
- `url`: Live URL or localhost URL to test
- `qa_report`: Path to the QA report from qa-tester
- `story_id`: Story being validated
- `build_command`: Build command for the repo (e.g. `bun run build`, `npm run build`)

## Process

1. Read prior QA report
2. Run grounding commands (build, curl, ls)
3. Cross-validate each QA finding independently
4. Run end-to-end user journey
5. Generate certification report

## Output

- Certification report to `workspace/reports/qa/{date}-{target}-reality-check.md`
- Verdict: NEEDS WORK / CONDITIONALLY READY / READY
- If NEEDS WORK: specific revision requirements with file paths
- If 3rd cycle: escalation report per handoff template
