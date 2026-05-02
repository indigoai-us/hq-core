---
name: run-project
description: "Codex-native router for executing HQ PRD stories. Uses an honest runtime choice: interactive session execution for small projects, or Ralph/headless execution through the shell orchestrator with the Codex engine."
allowed-tools: Read, Bash(bash:*), Bash(jq:*), Bash(cat:*), Bash(tail:*), Bash(kill:*), Bash(ls:*), Bash(mkdir:*), Bash(nohup:*), Bash(echo:*), Bash(sleep:*), Bash(qmd:*), Bash(test:*)
argument-hint: "{project} [--status] [--resume] [--dry-run] [--interactive] [--ralph-mode] [--engine codex|claude]"
---

# Run Project — Codex Router

Codex does not have the same runtime primitives as Claude Code. Do not route this skill by pretending `Task`, `Plan` sub-agents, `ExitPlanMode`, `/checkpoint`, or `/compact` are available. Pick an execution mode that maps to real Codex capabilities.

**User's input:** $ARGUMENTS

## Script Resolution

Resolve the shell orchestrator before any shell delegation:

1. Prefer `scripts/run-project.sh` if it exists.
2. Otherwise use `.claude/scripts/run-project.sh`.
3. If neither exists, stop with a clear error.

Store the chosen path as `{run_project_script}`. In this HQ workspace today, the expected path is `.claude/scripts/run-project.sh`.

## Step 1 — Parse Arguments

Extract from `$ARGUMENTS`:

- `{project}` — project name, required unless `--status` or `--help`
- `--status` — show orchestrator status, then stop
- `--dry-run` — show story order, then stop
- `--resume` — pass through to the chosen execution path
- `--interactive` or `--session-mode` — parent-driven Codex execution
- `--ralph-mode` — background/headless shell orchestrator
- `--engine codex|claude` — engine for Ralph/headless execution; default to `codex` in Codex sessions
- `--builder codex|claude` — backward-compatible alias for `--engine`
- Other shell-orchestrator flags (`--swarm`, `--tmux`, `--timeout`, `--retry-failed`, `--in-place`, `--checkin-interval`, `--codex-autofix`, `--no-monitor`) pass through only to Ralph/headless mode

If no execution mode is supplied, run an interactive preflight and recommend one:

- 1-2 incomplete stories: recommend `--interactive`
- 3-6 incomplete stories: recommend `--interactive` if user steering matters, otherwise `--ralph-mode --engine codex`
- 7+ incomplete stories, `--swarm`, `--tmux`, or unattended language: recommend `--ralph-mode --engine codex`

Ask before changing execution semantics. If structured question tooling is unavailable, use the plain-text fallback required by `.claude/policies/hq-codex-decision-gate-fallback.md`.

## Step 2 — Status, Help, and Dry Run

Use `{run_project_script}`:

```bash
bash {run_project_script} --status
bash {run_project_script} --help
bash {run_project_script} --dry-run {project}
```

Display the important output to the user and stop.

## Step 3 — Interactive Codex Execution

Interactive mode is parent-driven. It replaces Claude session-mode for Codex.

Use when the project is small enough for the parent session and the user may want to steer implementation decisions.

Process:

1. Resolve and read `prd.json`.
2. Read only applicable policy frontmatter first; read full rule text only for hard rules that apply to the project.
3. Write a durable plan file to `workspace/orchestrator/{project}/codex-session-plan.md` containing:
   - project, company, repo path, branch base, resume state
   - incomplete story order
   - acceptance criteria and declared files
   - applicable policy rules
   - quality gates
   - chosen mode: `interactive`
4. Ask the user to approve, adjust, or switch to Ralph/headless mode.
5. Execute one story at a time in the parent session:
   - make edits directly
   - run back-pressure checks
   - commit per story
   - mark `passes: true` only after verification
   - update `workspace/orchestrator/{project}/state.json`
6. Pause between stories and ask continue / adjust / stop.

Do not spawn an end-to-end `/execute-task` sub-agent in Codex interactive mode unless the user explicitly asks for delegated agent work. Bounded helper agents are okay only when explicitly requested or clearly available, and they must return compact structured output.

## Step 4 — Ralph/Headless Codex Execution

Use when the project is long-running, unattended, swarm/tmux-oriented, or when process isolation matters more than per-edit steering.

Launch with the Codex engine:

```bash
cd /Users/corey/HQ && \
  nohup bash {run_project_script} {project} {passthrough_flags} --engine codex --no-permissions \
  > workspace/orchestrator/{project}/run.log 2>&1 &
echo "PID:$!"
```

If `{run_project_script}` does not support `--engine`, use the legacy equivalent:

```bash
bash {run_project_script} {project} {passthrough_flags} --builder codex --no-permissions
```

Monitor progress from:

- `workspace/orchestrator/{project}/state.json`
- `workspace/orchestrator/{project}/progress.txt`
- `workspace/orchestrator/{project}/run.log`

Every poll:

1. Read state with `jq -r '.status'`.
2. Tail only new progress lines.
3. Check PID with `kill -0`.
4. If paused, surface the reason and ask resume / abort / detach.
5. If completed, summarize state, report path, commits, and failed/skipped stories.

## Step 5 — Completion

After either mode completes:

1. Confirm all intended stories have `passes: true`.
2. Confirm commits exist for completed stories.
3. Run project quality gates or report why they were skipped.
4. Run `qmd update 2>/dev/null || true`.
5. Ask whether to document release, run a retrospective, or end here.

## Rules

- **Do not reference `.Codex/commands/run-project.md` as required source** — that file may not exist. This skill is the Codex router.
- **Do not assume Claude-only primitives** — `Task`, `ExitPlanMode`, `/checkpoint`, and `/compact` are not Codex requirements.
- **Default engine in Codex is Codex** — Ralph/headless mode should pass `--engine codex` or legacy `--builder codex`.
- **Preserve HQ invariants** — PRD `userStories[].passes`, file locks, active-run coordination, commits per story, and quality gates remain required regardless of engine.
- **Ask before mode changes** — interactive vs Ralph/headless is a user-facing execution semantic. Preserve the decision gate with text fallback if needed.
