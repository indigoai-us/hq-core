---
name: run-project
description: Codex-native router for executing HQ PRD stories. Default inline uses filesystem-mediated worker-phase spawn_agent workers; explicit interactive mode runs directly in the parent; Ralph/headless runs the same inline worker loop unattended (auto-advance, no pauses).
allowed-tools: Read, spawn_agent, wait_agent, Bash(bash:*), Bash(jq:*), Bash(cat:*), Bash(tail:*), Bash(kill:*), Bash(ls:*), Bash(mkdir:*), Bash(echo:*), Bash(sleep:*), Bash(qmd:*), Bash(test:*), Bash, Write, AskUserQuestion, Task
argument-hint: "{project} [--status] [--resume] [--dry-run] [--inline] [--interactive] [--ralph-mode] [--in-place] [--timeout N]"
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
- `--ralph-mode` — the same inline worker loop as default, run unattended: skip the preflight approval, auto-advance through every story without between-story pauses, and report once at the end
- `--in-place` — (ralph) skip feature-branch pre-creation; work on the current checkout
- `--timeout N` — (ralph) per-story wall-clock budget in minutes before a story is marked `blocked: TIMEOUT`
- `--resume` continues from the next incomplete story (read from `state.json`)

If no execution mode is supplied, route to `--inline`. This is the default because it preserves the Ralph story loop and keeps implementation context out of the parent session.

Use `--interactive` only when the user asks to steer edits directly in the parent session. Use `--ralph-mode` for long unattended runs where you do not want to be prompted between stories — it executes the identical worker-authoritative story loop, just without the pauses.

**Recommendation posture:** always recommend `--inline`. Inline runs **continuously — no pause between stories** — except when either condition holds:

1. The PRD has **more than 10 incomplete stories** → pause at the preflight plan for one approval, then run continuously.
2. A story **requires session mode** (its notes or classification demand parent-driven interactive steering) → pause before that story only, run it interactively, then resume continuous flow.

Everything else auto-continues exactly like ralph-mode. Failed or blocked stories still stop the queue.

> **Note on the legacy detached orchestrator.** Earlier versions of this skill launched a detached shell subprocess (`nohup bash run-project.sh … --engine claude`) that ran one headless builder per story. That path is retired. `run-project.sh`'s execution loop is frozen and kept only for `--status`, `--dry-run`, and `--help`; it no longer runs stories, and it has no `claude` builder. Ralph now runs inline in the active session — no detached process, no per-story subprocess, no `claude -p` billing surface. The `--engine`/`--builder`, `--swarm`, `--tmux`, `--codex-autofix`, and `--no-monitor` flags belonged to that retired loop and are no longer accepted.

## Step 2 — Status, Help, and Dry Run

Use `{run_project_script}`:

```bash
bash {run_project_script} --status
bash {run_project_script} --help
bash {run_project_script} --dry-run {project}
```

Display the important output to the user and stop.

## Step 2.5 — Design-Lock Check (soft gate)

Before execution, read the project's `prd.json` and check `metadata.designLocked`.

- If `designLocked: true` (or the project has no UI surface) — proceed silently.
- If the PRD is **UI-bearing** (stories reference screens, pages, components, or `metadata.designRef`/`audiences` imply a user-facing interface) and `designLocked` is absent or false — surface a one-line **soft warning**: "Heads up — design isn't locked for `{project}`. Consider `/storyboard {project}` first to lock visuals and fold any design changes into the PRD before building. Proceed anyway? [Y/n]"

This is advisory, not a hard stop — many projects (CLIs, infra, libraries) have no visual surface and should proceed without friction. Honor an explicit "yes/proceed" and continue.

## Step 3 — Default Inline Codex Execution

Inline mode is story-delegated. The Codex parent session plans and coordinates; each story runs in one fresh `worker` agent that invokes `/execute-task {project}/{story-id}` internally. `/execute-task` then maps its worker phases to nested Codex `spawn_agent` calls via `.claude/skills/execute-task/SKILL.md`.

### 3a. Preflight Plan

Spawn exactly one read-only explorer:

```
spawn_agent({
  agent_type: "explorer",
  reasoning_effort: "low",
  message: "Read and analyze the PRD for {project}. Resolve prd.json, identify incomplete userStories, sort by dependencies then priority then array order, classify each story using /execute-task rules, identify worker sequences, read applicable hard policy rules, and return only a concise markdown implementation plan followed by a JSON block with project, company, repoPath, ordered_stories, hard_policies, quality_gates, and resume_from."
})
wait_agent(...)
```

Display the plan. If the queue has **≤10 incomplete stories and none require session mode**, proceed directly into the story loop without an approval stop. Otherwise (>10 stories, or session-mode stories present) ask the user to approve, adjust, switch to `--interactive`, switch to `--ralph-mode`, or stop. If structured question tooling is unavailable, use the plain-text fallback required by `core/policies/hq-codex-decision-gate-fallback.md`.

### 3b. Story Loop

For each approved incomplete story:

1. Announce story ID, title, and planned worker sequence.
2. Perform only lightweight parent orchestration: branch setup, state file update, and best-effort Linear sync.
3. Spawn exactly one story worker:

```
spawn_agent({
  agent_type: "worker",
  reasoning_effort: "low",
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
10. Auto-continue to the next incomplete story until the queue is empty or a story is `failed`/`blocked` (then surface and stop). Pause only per the recommendation-posture exceptions in Step 1: >10 incomplete stories (single preflight approval) or a story that requires session mode (pause before that story only).

### 3c. Regression Gates

Every 3 completed stories, run budget-aware `metadata.qualityGates` in one Codex `worker` agent with `reasoning_effort: "low"` and require compact JSON. Default to gates for repos touched since the last gate; run the full matrix at final completion, before deploy, after high-risk cross-repo contract changes, or when explicitly requested. Capture detailed logs to files and keep the parent transcript to the compact return:

```json
{"passed": true, "scope": "changed-repos", "gate_results": {"<gate>": "pass"}, "failures": []}
```

On failure, surface the summary and ask whether to fix, adjust, stop, or switch to Ralph/headless mode.

**Two regression layers, do not conflate them.** This every-3-stories quality gate is the *coarse* layer. The *fine* layer runs inside every story: when a story has non-empty `e2eTests`, `/execute-task`'s acceptance-test-writer phase writes `{repo}/__tests__/stories/{id}.test.ts` and then runs the **entire** `__tests__/stories/` suite as back-pressure — so every story re-verifies all prior stories' acceptance criteria and a regression (story N breaking story A) is caught immediately, not up to 3 stories later. A failing prior-story test is a back-pressure failure for the current story (the worker returns `all_story_tests_pass: false`). The orchestrator does not need to schedule this — it is part of the story worker's contract — but must treat such a story as not `passed`.

### 3d. Budget Guardrails

- Use exactly one preflight explorer, one story worker per story, and one regression-gate worker at gate cadence.
- Do not simulate `/execute-task` by spawning worker-phase agents from the parent. If the story worker cannot run `/execute-task`, pause and switch modes.
- **Prefer sub-agent swarming for speed.** When incomplete stories are mutually independent (no dependency edges between them and no overlapping declared files), spawn their story workers **in parallel** — one worker per story, dispatched in the same batch — instead of serially. Validate each returned JSON, worker proof, and commit per story as replies arrive; run regression gates after the batch. Stories with dependencies or file overlap still run sequentially. Extra review or QA agents beyond the story workers still require a high-risk trigger or explicit user opt-in after naming the cost.
- Do not read raw test logs, full `*.output.json`, or long command output in the parent. Use compact JSON, strip `stdout_tail` / `stderr_tail`, or cap inspection with `tail -c`.

## Step 4 — Parent-Driven Interactive Codex Execution

Interactive mode is parent-driven. It replaces Claude session-mode for Codex.

Use when the project is small enough for the parent session and the user may want to steer implementation decisions.

Codex interactive mode is direct parent execution, not proof that the HQ worker pipeline ran. If the user asks for worker-backed execution, or if a PRD/story requires `workers_run`, worker handoffs, or `/execute-task` semantics, stop and route to Ralph/headless (the unattended inline worker loop).

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

## Step 5 — Ralph/Headless Unattended Execution

Use when the project is long-running and the user wants it to run to completion without being prompted between stories.

Ralph/headless is **the same inline worker loop as Step 3, run unattended.** It does not launch a detached subprocess and it does not use a separate engine — it executes the identical story-delegated `spawn_agent(agent_type: "worker")` loop in the active session, worker-authoritative as always.

**5.0 — Pre-flight (run ONCE, before the loop starts).** Skipping the *approval pause* (operational step 1 below) must not skip *validation*. Before auto-advancing, the orchestrator must:

1. **Pre-create the feature branch** from `metadata.baseBranch` unless `--in-place` was passed — never let an unattended run discover mid-loop that it has been committing to the wrong branch (`run-project-precreate-branch-before-ralph`).
2. **Scan the PRD for stories whose acceptance requires interactive input** (a decision the worker would surface via `AskUserQuestion`) and mark them `blocked` up front with reason `NEEDS_INTERACTION` — do not let them wedge the loop mid-run (`hq-cmd-run-project-no-askuserquestion-stories-in-ralph-mode`). Workers in ralph mode never call `AskUserQuestion`.
3. **Verify the target repo + branch resolve and the tree is clean.** Abort with a clear message if not — an unattended run on a dirty or missing tree is never correct.

If any pre-flight check cannot be satisfied, stop and surface it; do not start the loop.

The operational differences from default inline are then:

1. **Skip the preflight approval gate (Step 3a).** Still spawn the one read-only explorer to build the plan, but do not pause for approval — log the plan to `workspace/orchestrator/{project}/codex-session-plan.md` and proceed.
2. **Auto-advance.** Run the Step 3b story loop for every approved incomplete story back to back. Do not pause between stories (Step 3b.10 already auto-advances; ralph-mode also skips the >10-story and session-mode pauses). All per-story invariants still hold: JSON-validate the worker return, enforce the worker-proof gate, verify parent-visible commits, mark `passes: true` only after verification, and update `state.json` after each story.
3. **Run regression gates on cadence.** Apply Step 3c every 3 completed stories exactly as in inline mode.
4. **Report once.** Emit one compact line per story to the transcript (`[{story_id}] {status} · {files_changed} files · {first_commit_short_sha}`); send anything longer to `workspace/threads/journal/<date>/<story-id>.md`. Surface a single summary at the end rather than pausing throughout.
5. **Bound wedge time.** A worker that never returns must not stall the run forever. Set a per-story soft budget (default ~20 min; honor `--timeout N` minutes if passed). If a story's `wait_agent` exceeds it, treat the story as `blocked` with reason `TIMEOUT`, stop, and surface it — do not silently move on. Slow back-pressure (e.g. heavy E2E) is the usual cause; the bound keeps an unattended run from hanging indefinitely.

Stop and surface to the user mid-run only on a hard blocker: a story that lands `blocked` (including `INVALID_RETURN_FORMAT`, `NEEDS_INTERACTION`, or `TIMEOUT`), a failed regression gate (coarse 3-story gate or a per-story `all_story_tests_pass: false`), or a worker that cannot run `/execute-task`. Do not silently skip past a blocked story to the next one — auto-advance applies to *passed* stories only.

Because the loop runs in-session, there is no PID, `run.log`, or detached process to poll. Progress lives in `state.json` and `progress.txt`, which the loop updates as it goes; `--status` and `--dry-run` against `{run_project_script}` remain available for out-of-band inspection.

## Step 6 — Completion

After either mode completes:

1. Confirm all intended stories have `passes: true`.
2. Confirm commits exist for completed stories.
3. Run project quality gates or report why they were skipped.
4. Run `qmd update 2>/dev/null || true`.
5. **Auto-checkpoint** <!-- AUTO-CHECKPOINT-ON-COMPLETION -->. Save a lightweight checkpoint so a fresh session can resume without a manual handoff. Codex does **not** use the `/checkpoint` primitive — write the thread file DIRECTLY: `workspace/threads/T-{UTC YYYYMMDD-HHMMSS}-auto-run-project-{project}.json` with `thread_id`, `version: 1`, `type: "auto-checkpoint"`, `created_at`, `updated_at`, `workspace_root`, `cwd`, `git: { branch, current_commit, dirty }`, `conversation_summary` (stories passed / blocked this run), `files_touched`, `next_steps`, and `metadata: { title: "Auto: run-project {project}", tags: ["auto-checkpoint", "run-project"], trigger: "run-project-complete" }`. **Dedup:** if an auto-checkpoint thread (`workspace/threads/T-*-auto-*.json`) was already written for this run, upgrade/reuse it instead of writing a duplicate. Cheap only — no INDEX/`recent.md`/`qmd` rebuild.
6. Ask whether to document release, run a retrospective, or end here.

## Rules

- **Do not reference `.Codex/commands/run-project.md` as required source** — that file may not exist. This skill is the Codex router.
- **Do not assume Claude-only primitives** — `Task`, `ExitPlanMode`, `/checkpoint`, and `/compact` are not Codex requirements. Use `spawn_agent` / `wait_agent` for default inline isolation.
- **Default is inline** — a bare `/run-project {project}` uses story-level `spawn_agent(agent_type: "worker")` execution and nested `/execute-task` worker phases. Inline auto-continues between stories (no pauses) unless the PRD has >10 incomplete stories or a story requires session mode; prefer parallel sub-agent swarming for independent stories.
- **Ralph/headless is the unattended inline loop** — it is the same worker-authoritative `spawn_agent(agent_type: "worker")` story loop as default inline, run without preflight approval or between-story pauses. There is no detached subprocess, no separate engine, and no `claude -p`. Do not pass or accept `--engine`/`--builder`; `run-project.sh` has no `claude` builder and its execution loop is frozen.
- **Preserve HQ invariants** — PRD `userStories[].passes`, file locks, active-run coordination, commits per story, and quality gates remain required in every mode.
- **Ask before mode changes** — switching from default inline to parent-driven interactive or Ralph/headless is a user-facing execution semantic. Preserve the decision gate with text fallback if needed.
- **Budget mode is default** — Codex inline must prefer low-reasoning story delegation, compact JSON returns, bounded log reads, changed-repo regression gates, and no parent-side phase fanout.
