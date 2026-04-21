---
description: Execute a single task through coordinated worker phases (Ralph pattern)
allowed-tools: Task, Read, Write, Glob, Grep, Bash, AskUserQuestion
argument-hint: [project/task-id]
visibility: public
---

# /execute-task - Worker-Coordinated Task Execution

Run the `/execute-task` skill to execute a single user story through coordinated worker phases (Ralph pattern). Each worker handles their domain and passes context to the next. Runtime-agnostic canonical logic lives in the skill.

**Arguments:** $ARGUMENTS

## Steps

1. Load the execute-task skill from `.claude/skills/execute-task/SKILL.md`
2. Parse `$ARGUMENTS` as `{project}/{task-id}` (or interactive picker if missing)
3. **Repo-run preflight:** Resolve `$REPO_PATH` from the task's prd.json, then run `bash scripts/repo-run-registry.sh check "$REPO_PATH"`. On exit 2, the registry has found a live foreign owner (another `/run-project` sweeping the repo). Display the owner row(s) and abort unless the user passes `--ignore-active-runs`. Never bypass silently. Policy: `.claude/policies/repo-run-coordination.md`.
4. Execute the 9-step pipeline: parse args → load task spec + codex check → classify story + build worker sequence → init state + acquire checkout + file locks + load policies → run phases (acceptance-test-writer → dev → codex-reviewer → dev-qa-tester) with inline codex review + back-pressure auto-recovery → verify sub-agent commits → run quality gates → complete or fail task → auto-checkpoint thread file

## After Execute-Task

- File locks in `{repo}/.file-locks.json` + state.json `checkedOutFiles` are released on completion/failure
- Audit log entries appended at task_started / phase_completed / task_completed / task_failed
- Model usage logged to `workspace/metrics/model-usage.jsonl`
- Linear sync is best-effort (cross-company guard enforced)
- On success: thread file written to `workspace/threads/`, INDEX regen + `qmd update` run
- Sub-agents MUST commit their own work before returning — orchestrator verifies and warns if uncommitted diffs remain
