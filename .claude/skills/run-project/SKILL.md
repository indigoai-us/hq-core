---
name: run-project
description: "Codex-native router for executing HQ PRD stories. Default inline uses story-level spawn_agent workers; explicit interactive mode runs directly in the parent; Ralph/headless uses the shell orchestrator."
allowed-tools: Read, spawn_agent, wait_agent, Bash(bash:*), Bash(jq:*), Bash(cat:*), Bash(tail:*), Bash(kill:*), Bash(ls:*), Bash(mkdir:*), Bash(nohup:*), Bash(echo:*), Bash(sleep:*), Bash(qmd:*), Bash(test:*)
argument-hint: "{project} [--status] [--resume] [--dry-run] [--inline] [--interactive] [--ralph-mode] [--engine codex|claude]"
---

# Run Project — Codex Router

Codex does not use Claude Code's `Task`, `Plan` sub-agents, `ExitPlanMode`, `/checkpoint`, or `/compact` primitives. It does have `spawn_agent` / `wait_agent`, so the default inline path maps Claude's per-story `Task` boundary to a Codex `worker` agent and maps read-only plan preflight to a Codex `explorer` agent.

**User's input:** $ARGUMENTS

## Script Resolution

Resolve the shell orchestrator before any shell delegation:

1. Prefer `core/scripts/run-project.sh` if it exists.
2. Otherwise use `.claude/scripts/run-project.sh`.
3. If neither exists, stop with a clear error.

Store the chosen path as `{run_project_script}`. In this HQ workspace today, the expected path is `.claude/scripts/run-project.sh`.

## Step 1 — Parse Arguments

Extract from `$ARGUMENTS`:

- `{project}` — project name, required unless `--status` or `--help`
- `--status` — show orchestrator status, then stop
- `--dry-run` — show story order, then stop
- `--resume` — pass through to the chosen execution path
- `--inline` — story-level Codex sub-agent execution (default)
- `--interactive` or `--session-mode` — parent-driven Codex execution
- `--ralph-mode` — background/headless shell orchestrator
- `--engine codex|claude` — engine for Ralph/headless execution; default to `claude` for worker-authoritative runs
- `--builder codex|claude` — backward-compatible alias for `--engine`
- Other shell-orchestrator flags (`--swarm`, `--tmux`, `--timeout`, `--retry-failed`, `--in-place`, `--checkin-interval`, `--codex-autofix`, `--no-monitor`) pass through only to Ralph/headless mode

If no execution mode is supplied, route to `--inline`. This is the default because it preserves the Ralph story loop and keeps implementation context out of the parent session.

Use `--interactive` only when the user asks to steer edits directly in the parent session. Use `--ralph-mode` for long unattended, swarm, tmux, or process-isolated runs.

## Step 2 — Status, Help, and Dry Run

Use `{run_project_script}`:

```bash
bash {run_project_script} --status
bash {run_project_script} --help
bash {run_project_script} --dry-run {project}
```

Display the important output to the user and stop.

## Step 3 — Default Inline Codex Execution

Inline mode is story-delegated. The Codex parent session plans and coordinates; each story runs in one fresh `worker` agent that invokes `/execute-task {project}/{story-id}` internally. `/execute-task` then maps its worker phases to nested Codex `spawn_agent` calls via `.claude/skills/execute-task/SKILL.md`.

### 3a. Preflight Plan

Spawn exactly one read-only explorer:

```
spawn_agent({
  agent_type: "explorer",
  message: "Read and analyze the PRD for {project}. Resolve prd.json, identify incomplete userStories, sort by dependencies then priority then array order, classify each story using /execute-task rules, identify worker sequences, read applicable hard policy rules, and return only a concise markdown implementation plan followed by a JSON block with project, company, repoPath, ordered_stories, hard_policies, quality_gates, and resume_from."
})
wait_agent(...)
```

Display the plan and ask the user to approve, adjust, switch to `--interactive`, switch to `--ralph-mode`, or stop. If structured question tooling is unavailable, use the plain-text fallback required by `core/policies/hq-codex-decision-gate-fallback.md`.

### 3b. Story Loop

For each approved incomplete story:

1. Announce story ID, title, and planned worker sequence.
2. Perform only lightweight parent orchestration: branch setup, state file update, and best-effort Linear sync.
3. Spawn exactly one story worker:

```
spawn_agent({
  agent_type: "worker",
  message: <<PROMPT
Execute story {project}/{story-id} by running /execute-task {project}/{story-id}.

You are not alone in the codebase. Own only this story and its declared files;
do not revert edits made by others; adapt to existing changes you encounter.

When /execute-task asks for a Task sub-agent, use its Codex runtime adapter so
the nested HQ worker phases run as isolated Codex agents.

Commit your story work before returning. If your runtime returns an integration
patch instead of a parent-visible commit, say so in notes and list every changed
path.

RETURN CONTRACT: json

Return ONLY this JSON object — no prose, no markdown fences, nothing before or after:
{
  "status": "passed" | "failed" | "blocked",
  "story_id": "{story-id}",
  "commits": ["<short-sha>", ...],
  "files_changed": <int>,
  "back_pressure": {
    "tests": "pass" | "fail" | "skip",
    "lint": "pass" | "fail" | "skip",
    "typecheck": "pass" | "fail" | "skip",
    "build": "pass" | "fail" | "skip"
  },
  "workers_run": ["architect", "backend-dev", ...],
  "notes": "<1-2 sentence summary; include blocker description if status != passed>"
}
PROMPT
})
wait_agent(...)
```

4. Validate the reply as JSON with `jq -e .` (or equivalent). If invalid, retry exactly once with this stricter prompt addition: `Your previous reply was not valid JSON. Emit ONLY the JSON object specified above. No prose, no fences, no trailing newline.` If still invalid, mark the story `blocked` with reason `INVALID_RETURN_FORMAT`, surface to user, do NOT advance to the next story. (Enforced by [ralph-orchestrator-context-discipline](../../../core/policies/ralph-orchestrator-context-discipline.md).)
5. Enforce the worker proof gate: passed stories must include at least one real HQ worker ID in `workers_run`; reject placeholder-only values like `codex`, `worker`, `general-purpose`, or `commit`.
6. Verify commits are parent-visible with `git log --oneline -n {len(commits)}`. If the worker produced an integration patch instead of a visible commit, review/integrate it in the parent and create the story commit before continuing.
7. Mark `passes: true` only after status is `passed`, worker proof passes, back-pressure is acceptable, and commit verification succeeds.
8. Update `workspace/orchestrator/{project}/state.json`.
9. Narrate one line per story to the user: `[{story_id}] {status} · {files_changed} files · {first_commit_short_sha}`. Anything longer goes to `workspace/threads/journal/<date>/<story-id>.md`, not the parent transcript.
10. Pause between stories for continue / adjust / stop.

### 3c. Regression Gates

Every 3 completed stories, run `metadata.qualityGates` in one Codex `worker` agent and require compact JSON:

```json
{"passed": true, "gate_results": {"<gate>": "pass"}, "failures": []}
```

On failure, surface the summary and ask whether to fix, adjust, stop, or switch to Ralph/headless mode.

## Step 4 — Parent-Driven Interactive Codex Execution

Interactive mode is parent-driven. It replaces Claude session-mode for Codex.

Use when the project is small enough for the parent session and the user may want to steer implementation decisions.

Codex interactive mode is direct parent execution, not proof that the HQ worker pipeline ran. If the user asks for worker-backed execution, or if a PRD/story requires `workers_run`, worker handoffs, or `/execute-task` semantics, stop and route to Ralph/headless with `--engine claude`.

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
   - do not claim `workers_run` or worker-backed completion unless `/execute-task` actually ran through the worker system
   - update `workspace/orchestrator/{project}/state.json`
6. Pause between stories and ask continue / adjust / stop.

Do not spawn an end-to-end `/execute-task` sub-agent in Codex interactive mode unless the user explicitly asks for delegated agent work. Bounded helper agents are okay only when explicitly requested or clearly available, and they must return compact structured output.

## Step 5 — Ralph/Headless Codex Execution

Use when the project is long-running, unattended, swarm/tmux-oriented, requires worker-backed story execution, or when process isolation matters more than per-edit steering.

Launch with the worker-authoritative Claude engine:

```bash
cd ~/HQ && \
  nohup bash {run_project_script} {project} {passthrough_flags} --engine claude --no-permissions \
  > workspace/orchestrator/{project}/run.log 2>&1 &
echo "PID:$!"
```

If `{run_project_script}` does not support `--engine`, use the legacy equivalent:

```bash
bash {run_project_script} {project} {passthrough_flags} --builder claude --no-permissions
```

`--engine codex` is an explicit opaque-builder opt-in, not the default worker path. It requires `HQ_ALLOW_CODEX_OPAQUE_BUILDER=1` and must not be described as worker-authoritative until Codex can prove worker participation.

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

## Step 6 — Completion

After either mode completes:

1. Confirm all intended stories have `passes: true`.
2. Confirm commits exist for completed stories.
3. Run project quality gates or report why they were skipped.
4. Run `qmd update 2>/dev/null || true`.
5. Ask whether to document release, run a retrospective, or end here.

## Rules

- **Do not reference `.Codex/commands/run-project.md` as required source** — that file may not exist. This skill is the Codex router.
- **Do not assume Claude-only primitives** — `Task`, `ExitPlanMode`, `/checkpoint`, and `/compact` are not Codex requirements. Use `spawn_agent` / `wait_agent` for default inline isolation.
- **Default is inline** — a bare `/run-project {project}` uses story-level `spawn_agent(agent_type: "worker")` execution and nested `/execute-task` worker phases.
- **Default engine in Codex is Codex** — Ralph/headless mode should pass `--engine codex` or legacy `--builder codex`.
- **Preserve HQ invariants** — PRD `userStories[].passes`, file locks, active-run coordination, commits per story, and quality gates remain required regardless of engine.
- **Ask before mode changes** — switching from default inline to parent-driven interactive or Ralph/headless is a user-facing execution semantic. Preserve the decision gate with text fallback if needed.
