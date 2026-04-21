---
description: Run a project — default is inline execution; --ralph-mode for background orchestrator
allowed-tools: Bash, Read, Write, AskUserQuestion, Task
argument-hint: [project-name] or [--status] or [--help]
visibility: public
---

<!-- THIN-ROUTER SPLIT — this .md is the canonical docs/examples/flags source. The paired SKILL.md is a minimal dispatch shim. They stay forked on purpose: one is human-facing docs, the other is a routing shim. -->

# /run-project — Project Executor

Executes PRD stories for a project. **Default mode is inline** — each incomplete story runs inside a fresh per-story Task sub-agent in the current Claude session. Pass `--ralph-mode` to run the legacy background orchestrator (`scripts/run-project.sh`) that spawns `claude -p` subprocesses for each story and polls state files from the parent. Pass `--session-mode` to use the plan-file-anchored inline shape.

Policy: `.claude/policies/run-project-default-is-inline.md` (hard).

**Arguments:** $ARGUMENTS

## Ralph Principle

"Pick a task, complete it, commit it."

- Fresh context per task (per-story Task sub-agent in default/inline mode; `claude -p` subprocess in `--ralph-mode`)
- Sub-agents do heavy lifting via `/execute-task`
- Back pressure keeps code on rails
- Handoffs preserve context between workers

## Execution Modes

| Mode | When | How |
|------|------|-----|
| **Default (inline)** | `/run-project {project}` with no execution-mode flag | Plan from PRD → user approves → execute each story in a per-story Task sub-agent (fresh context) that invokes `/execute-task` internally. See `## Inline Execution (Default)` below. |
| **inline (explicit)** | `--inline` flag | Silent alias for default. Same behavior as bare invocation. |
| **ralph-mode** | `--ralph-mode` flag | `nohup bash scripts/run-project.sh {project}` runs in background; each story spawns as an isolated `claude -p` subprocess; parent session polls `state.json`. Best for long unattended runs. See `## Ralph-Mode Execution (--ralph-mode)` below. |
| **session-mode** | `--session-mode` flag | Plan distilled into Claude Code plan file (with full policy rule text) → `ExitPlanMode` approval → parent session executes each story directly (Edit/Write/Bash); bounded helper sub-agents only (review, QA, E2E, design audit). No `/execute-task` wrapper. See `## Session-Mode Execution` below. |
| **tmux** | `--tmux` flag (implies `--ralph-mode`) | `run-project.sh` in tmux session (observe from phone) |
| **direct** | `bash scripts/run-project.sh` (CI/nohup/cron) | Direct shell execution, outside `/run-project` scope |

**Dispatch (Step 1 — applies to every invocation):**

Parse `$ARGUMENTS` into project name + passthrough flags:

- `--status`: delegate synchronously via `bash scripts/run-project.sh --status` (display + exit)
- `--dry-run`: delegate synchronously via `bash scripts/run-project.sh --dry-run {project}` (display + exit)
- `--help`: display flags table + exit
- `--session-mode`: route to **Session-Mode Execution** flow (see below). Incompatible with `--inline`, `--ralph-mode`, `--tmux`, `--swarm`, `--codex-autofix`, `--dry-run`, `--status` (error immediately on conflict).
- `--ralph-mode`: route to **Ralph-Mode Execution** flow (see below). Incompatible with `--inline` and `--session-mode` (error immediately on conflict).
- `--inline`: silent alias for default — route to **Inline Execution** (see below). Do NOT error or warn.
- No execution-mode flag present: route to **Inline Execution** (default).
- Empty (no project name): error — project name required
- All other flags pass through verbatim to the chosen execution path

**Hard policy:** `.claude/policies/run-project-default-is-inline.md` — a bare `/run-project {project}` MUST NOT launch `nohup bash scripts/run-project.sh ...`. That path requires `--ralph-mode`.

## Ralph-Mode Execution (--ralph-mode)

Opt-in background orchestrator. When `--ralph-mode` is passed, `/run-project` launches `scripts/run-project.sh` as a `nohup` background OS process and monitors progress via state file polling from the parent Claude session. Each story runs as an isolated `claude -p` subprocess (fresh context per story). Best for long unattended runs (8+ stories), CI-like execution, or when the user wants progress surfaced from a phone via `--tmux`.

### Step R2 — Validate PRD + Display Summary

**Plan-mode branch (REQUIRED when Claude Code plan mode is active):**

If the session is currently in plan mode (i.e. `/run-project --ralph-mode` was invoked while plan mode was on), the parent must NOT read prd.json directly. Instead, delegate to the same Plan sub-agent used by the default/inline Step 2 (see above). The sub-agent returns a condensed plan + JSON; parent presents it via `ExitPlanMode`. On approval, the JSON becomes the passthrough-state for Step R3's background launch — no re-read required.

This keeps plan-mode preflight out of the parent transcript. After approval, the plan is durable in `ordered_stories` JSON; the background orchestrator re-reads prd.json from disk in its own process.

**Normal-mode branch (plan mode not active):**

1. Resolve PRD path: `companies/{co}/projects/{project}/prd.json` (use qmd search if needed)
2. Read prd.json → display: project name, total stories, completed, remaining
3. Ensure `workspace/orchestrator/{project}/` dir exists (create if not)

The normal branch reads ~5K tokens into the parent, but warm-start (Step 2.5) drops them before the poll loop. Acceptable cost for a one-shot read. Under plan mode, that compact can't run before `ExitPlanMode`, so delegation is mandatory instead of optional.

### Step R2.4 — Repo-Run Preflight (active-run coordination)

**Why:** Prevents colliding with another live `/run-project` on the same repo.
Policy: `.claude/policies/repo-run-coordination.md`. Registry:
`workspace/orchestrator/active-runs.json`.

1. Resolve `$REPO_PATH` from prd.json (`repoPath` or manifest reverse lookup).
2. Run `bash scripts/repo-run-registry.sh check "$REPO_PATH"`.
3. On exit 0: proceed to Step 2.5.
4. On exit 2 (foreign owner found):
   - The registry prints the owner row(s) to stderr: command, project, PID, started_at.
   - Display them to the user verbatim.
   - Ask the user (AskUserQuestion) to choose:
     - **wait** — abort this `/run-project` invocation; re-run when the owner finishes.
     - **worktree** — create a sibling worktree (`git worktree add ../{repo}-wt-{project}`), cd into it, re-run `/run-project` from the worktree (the new registration will use `scope: worktree:{path}`).
     - **bypass** — pass `--ignore-active-runs` (sets `HQ_IGNORE_ACTIVE_RUNS=1` and appends a JSON audit row to `workspace/learnings/active-run-bypasses.jsonl`). Use only when the owner is verifiably dead.
   - Never bypass silently. Always require explicit user confirmation.

**Flag:** `--ignore-active-runs` — user-gated bypass. On confirmation, export
`HQ_IGNORE_ACTIVE_RUNS=1` for the session environment and continue. Append
`{ts, run_id, bypassed_by, target_repo, reason}` to
`workspace/learnings/active-run-bypasses.jsonl` before launching.

### Step R2.5 — Warm-Start (Checkpoint + Compact)

**Unconditional.** Runs every `--ralph-mode` invocation, regardless of current context usage. Preflight (PRD read, policy load, state rehydration, dry-run decisions) often consumes significant context before the orchestrator is even ready. Warm-start resets the parent session before the long-running poll loop begins.

1. Run `/checkpoint` — writes a thread file capturing: project name, PRD path, incomplete story count, loaded policies, any preflight findings or blockers
2. Run `/compact` — clears conversation context

**Durability note:** All orchestration state is already on disk before this step runs — `workspace/orchestrator/{project}/state.json`, `{repo}/.file-locks.json`, `prd.json`, loaded policy digests. Compaction drops only conversation context, so Step R3's background launch and Step R4's poll loop read fresh from disk and continue without loss.

**Skip conditions:** `--status`, `--dry-run`, and `--help` already exit before this point (Step 1 routes them synchronously), so warm-start never runs for them.

### Step R3 — Launch Background

```bash
# Bash tool with run_in_background: true
cd /Users/{your-name}/Documents/HQ && \
  nohup bash scripts/run-project.sh {project} {passthrough_flags} --no-permissions \
  > workspace/orchestrator/{project}/run.log 2>&1 &
echo "PID:$!"
```

Capture the PID from output. Announce to user:
> Launched `run-project.sh` for **{project}** (PID {pid}, `--ralph-mode`). Monitoring progress...

### Step R4 — Poll Loop

Execute sequential Bash calls every ~30 seconds. Each poll:

1. **Read state**: `jq -r '.status' workspace/orchestrator/{project}/state.json`
2. **Read progress delta**: `tail -n +{last_line_count} workspace/orchestrator/{project}/progress.txt`
3. **Check PID alive**: `kill -0 {pid} 2>/dev/null && echo "ALIVE" || echo "DEAD"`
4. **Print new progress lines** to user (only lines not yet shown)
5. **Branch on status**:
   - `in_progress` + PID alive → sleep 30, continue polling
   - `paused` → read last 20 lines of `run.log`, surface pause reason. Prompt user: **resume** (`bash scripts/run-project.sh --resume {project} --no-permissions`) / **abort** (kill PID)
   - `completed` → exit poll loop → Step 5
   - PID dead + status not `completed` → tail `run.log` for error context, report to user

**Poll ceiling:** After 4 hours (480 cycles), warn user and offer to detach monitoring. Script keeps running — reattach with `/run-project --status`.

### Step R5 — Completion Summary

1. Read final `state.json` → stories completed/failed, regression gate results
2. Read `progress.txt` → full run log
3. Read `workspace/reports/{project}-summary.md` (if generated by completion flow)
4. Display formatted summary to user

### Failure / Pause Handling

The script runs headless (no tty) — it takes non-interactive paths automatically:
- **Story failure**: auto-retry once, then skip to retry queue
- **Regression gate failure**: auto-pause (sets `state.json` status to `paused`)
- Claude's poll loop detects `paused` state and surfaces the choice to the user

## Inline Execution (Default)

Interactive, plan-first execution in the current session — **this is the default shape** when `/run-project {project}` is called with no execution-mode flag. Best for small-to-medium projects (3-8 stories) where user input is valuable — ambiguous specs, design decisions, creative work. `--inline` is accepted as a silent alias for back-compat (no warning, no error).

**Isolation model (per-story sub-agent):** Each story executes inside a single `general-purpose` Task sub-agent (not per-worker). The sub-agent invokes `/execute-task` internally, which in turn spawns the usual per-worker sub-agents. The parent session holds only approved-plan state plus a compact JSON summary per story — raw worker output never enters the parent context. This matches Ralph's "pick task, complete, commit, repeat" at the story level and keeps the parent session usable across long runs (5+ stories).

### Step 1 — Parse + Validate

1. Resolve PRD path: `companies/{co}/projects/{project}/prd.json`
2. Read prd.json → display: project name, total stories, completed, remaining
3. Ensure `workspace/orchestrator/{project}/` dir exists

**Incompatible flags** — error immediately if combined with the default (inline) path (same rules apply to the `--inline` alias):
- `--ralph-mode` (default is inline; `--ralph-mode` is the explicit background orchestrator opt-in)
- `--session-mode` (that path uses plan-file-anchored inline, not per-story Task sub-agents)
- `--swarm` (inline is sequential by nature)
- `--tmux` (no background process to observe)
- `--codex-autofix` (user handles issues interactively)

### Step 2 — Generate Plan from PRD (delegated)

**Isolation goal:** The parent session must NOT read prd.json, policies, or state.json directly. Those reads accumulate 10K+ tokens that are dead weight after plan approval. Delegate to a single Plan sub-agent; the parent only sees the rendered plan.

1. Spawn exactly ONE Task sub-agent to do the heavy preflight read:

   ```
   Task({
     subagent_type: "Plan",
     description: "Generate execution plan for {project}",
     prompt: <<PROMPT
       Read and analyze the PRD for project "{project}".

       Steps:
       1. Resolve PRD path: companies/{co}/projects/{project}/prd.json (qmd search if ambiguous)
       2. Read prd.json fully — all userStories, metadata, qualityGates
       3. Filter incomplete stories (passes: false), sort by: dependsOn resolved → priority asc → array order
       4. For each story, classify task type using /execute-task's rules and determine worker sequence
       5. Read applicable policies (companies/{co}/policies/*, repos/{repoPath}/.claude/policies/*, .claude/policies/*) — hard-enforcement only, frontmatter + rule
       6. Read workspace/orchestrator/{project}/state.json if it exists (for resume context)

       RETURN CONTRACT — your FINAL message MUST be EXACTLY this format (markdown block followed by JSON block, nothing else):

       ## Implementation Plan: {project}

       1. **{story-id}**: {title}
          - Workers: {worker-sequence}
          - Files: {files from PRD, or "not declared"}
          - ACs: {1-line summary}
       2. ...

       Policies loaded: {count} hard ({top 3 titles})
       Resume state: {fresh | resuming from {story-id}}

       ```json
       {
         "project": "{project}",
         "co": "{co}",
         "repoPath": "{repoPath or null}",
         "ordered_stories": [
           {"id": "{story-id}", "workers": ["..."], "files": ["..."], "branch": "{branch or null}"}
         ],
         "hard_policies": ["{policy-title}", ...],
         "quality_gates": ["{cmd}", ...],
         "resume_from": "{story-id or null}"
       }
       ```

       No prose before or after. No file dumps. No raw PRD content. Just the plan + JSON.
     PROMPT
   })
   ```

2. Parent displays the markdown plan verbatim (no re-reading PRD), stores the JSON as the approved-plan state for later steps.

3. **Enter plan mode** — user reviews, can request reordering or story adjustments (parent edits the JSON in place if needed; does not re-read PRD).

4. Wait for user approval via `ExitPlanMode` before proceeding.

**Why delegate:** Under Claude Code plan mode, every read in the parent is preserved in the transcript until autocompact fires at 75%. The Plan sub-agent has its own context window; when it returns, only the rendered plan + JSON enter the parent. This saves ~10K tokens that would otherwise block execution runway.

### Step 3 — Policies (already carried in plan JSON)

Do NOT re-load policies in the parent. The Plan sub-agent (Step 2) already surfaced hard-enforcement titles in the returned JSON. Display the count from `hard_policies.length` and move on. If the user wants to see a specific policy's full text, spawn a one-shot sub-agent to read it — never read policy files directly in the parent.

### Step 3.5 — Warm-Start (Checkpoint + Compact)

**Unconditional.** Runs after plan approval and policy load, before the first story executes. Inline mode runs all orchestration in-session, so preflight context (plan generation, user review, policy load) must be cleared to preserve headroom for the Ralph loop — which stays in-session for every story.

1. Run `/checkpoint` — writes a thread file capturing: project name, approved plan (story order + workers), loaded policies, pending story list
2. Run `/compact` — clears conversation context

**Durability note:** The approved plan is durable in `prd.json` (`passes` flags + story order) and `workspace/orchestrator/{project}/state.json`. Compaction drops only conversation — the loop resumes reading from disk in Step 4.

**Why both modes warm-start:** Default mode's parent session still runs the poll loop in-process (surfacing progress to the user), so preflight context bloat hurts it too. Inline mode is more obviously affected, but neither mode benefits from carrying preflight context into execution.

### Step 4 — Sequential Story Execution (Per-Story Sub-Agent Ralph Loop)

For each incomplete story in approved plan order, the parent session performs only lightweight orchestration and delegates the full worker pipeline to a fresh Task sub-agent.

**Parent-session work (kept minimal — 2-3 lines of context per story):**

1. **Announce**: display story ID, title, one-line summary of planned worker sequence
2. **Branch setup**: create/checkout `branchName` from `baseBranch` (if specified in PRD)
3. **Linear sync**: set In Progress (best-effort, non-blocking)

**Delegate to story sub-agent (Task tool):**

4. Spawn exactly ONE Task sub-agent for the story:

   ```
   Task({
     subagent_type: "general-purpose",
     model: CLAUDE_CODE_SUBAGENT_MODEL,   // opus
     description: "Execute story {story-id}",
     prompt: <<PROMPT
       Execute story {project}/{story-id} by running the /execute-task skill.

       Follow all existing execute-task behavior:
         - Load task spec from prd.json
         - Classify task type, select worker sequence
         - Run the full worker pipeline (architect → backend-dev → code-reviewer → QA, etc.)
         - Each worker runs in its own nested Task sub-agent with fresh context (standard execute-task behavior)
         - Enforce back pressure (tests, lint, typecheck, build) per worker
         - Commit all changes before returning (per "Sub-Agent Rules" in CLAUDE.md)
         - Mark passes:true in prd.json on success

       RETURN CONTRACT — your FINAL message MUST be EXACTLY this JSON, nothing else:

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

       No prose before or after. No markdown fences. No commentary. JSON only.
     PROMPT
   })
   ```

**Parent absorbs the JSON result (≤~300 tokens):**

5. Parse JSON. On parse failure, retry once with the same prompt + "Your last output was not valid JSON. Return ONLY the JSON object specified in the return contract." If retry fails, treat as `status: "blocked"` and surface the raw tail to the user.
6. **Render one line** per story, e.g.:
   `✓ US-007 · architect → backend-dev → code-reviewer · 12 files · tests ✓ lint ✓ typecheck ✓ · commit abc1234`
7. **Commit verification** (cheap, parent-side): `git log --oneline -n {len(commits)}` to confirm commits landed on current branch. Auto-commit any stragglers if sub-agent forgot (per CLAUDE.md "Sub-Agent Rules").
8. **User checkpoint**: from the JSON `status` + `notes`, ask:
   - **Continue** → proceed to next story (default if `status == "passed"`)
   - **Adjust** → user modifies next story's approach/ACs before execution
   - **Stop** → pause execution, preserve progress (resume later with `--inline --resume`)
9. **Mark complete**: set `passes: true` in prd.json (only if `status == "passed"`), update `state.json` with story result + commits
10. **Linear sync**: set Done + comment (best-effort, non-blocking)

**Context-preservation note:** The parent session gains only ~300-500 tokens per completed story (announce lines + JSON summary + one-line render). Compared to the previous per-worker-inline model, which could accumulate several thousand tokens per story from worker output, this preserves the parent context window across 5-8 story runs without hitting the 60% advisory.

### Step 5 — Regression Gates

Every 3 completed stories, run full `metadata.qualityGates` in a **one-shot Task sub-agent** so raw test output stays out of the parent context:

```
Task({
  subagent_type: "general-purpose",
  description: "Regression gates after {n} stories",
  prompt: "Run all metadata.qualityGates commands for {project}. Return ONLY:
           {\"passed\": bool, \"gate_results\": {<gate>: \"pass\"|\"fail\"}, \"failures\": [<brief summary lines>]}"
})
```

Parent renders `✓ Regression gates passed` or `✗ Regression gates failed: <summary>`. On failure, surface to user inline (no auto-pause/retry — user decides).

### Step 6 — Completion

Same as default mode but all inline (no `claude -p` spawning):
1. Board sync → `done`
2. Summary report → `workspace/reports/{project}-summary.md`
3. Doc sweep — run inline via Agent tool (not headless `claude -p`)
4. Document release — run `/document-release` inline
5. INDEX.md rebuild, manifest verification, `qmd update`
6. State → `status: "completed"`

## Session-Mode Execution (--session-mode)

Interactive, **plan-file-anchored** execution. The parent session executes each story directly (Edit/Write/Bash). Bounded helper sub-agents are allowed for review, QA, E2E, and design audit — but **no `/execute-task` sub-agent wrapper** (that is `--inline` behavior).

**Use when:** you want hands-on steering of story execution with a durable policy context lock. Mid-complexity projects (2-6 stories) where intra-story decisions benefit from in-session reasoning.

**Governing policy:** `.claude/policies/run-project-session-mode.md` (hard-enforcement). Preflight delegation governed by `.claude/policies/plan-mode-preflight-delegation.md`.

### Step S1 — Incompatibility Check

Error immediately if `--session-mode` is combined with `--inline`, `--tmux`, `--swarm`, `--codex-autofix`, `--dry-run`, or `--status`. Print: `--session-mode is incompatible with {flag}` and exit.

### Step S2 — Preflight Delegation (ONE Plan sub-agent)

Parent MUST NOT read prd.json, policies, state.json, or manifest directly. Spawn exactly ONE Task sub-agent:

```
Task({
  subagent_type: "Plan",
  description: "Materialize session-mode plan file for {project}",
  prompt: <<PROMPT
    Produce the plan file body for /run-project --session-mode {project}.

    Reads:
    1. companies/{co}/projects/{project}/prd.json (use qmd search if path ambiguous)
    2. companies/{co}/policies/*.md — hard + soft (skip _digest.md, example-policy.md, README.md)
    3. {repoPath}/.claude/policies/*.md — hard + soft (if repoPath present)
    4. .claude/policies/*.md — hard-enforcement ONLY, filtered to applies_to: [run-project, execute-task, task-execution, deploy, commit]
    5. workspace/orchestrator/{project}/state.json (if present, for resume context)
    6. companies/manifest.yaml — extract entry for {co}: vercel_team, aws_profile, dns_zones, services

    Produce:
    - Incomplete stories (passes: false), sorted by dependsOn → priority → array order
    - For each story: classify task type (reuse /execute-task classification) and derive advisory worker sequence
    - Full rule text (verbatim, not summarized) for each applicable policy — this is the "context lock"

    RETURN CONTRACT — your final message MUST be EXACTLY one fenced markdown block containing the plan file body, followed by one fenced JSON block with structured state. No prose before/after.

    Plan file body schema:

    # Session-Mode Plan: {project}

    ## Context
    - Company: {co} ({vercel_team} / {aws_profile})
    - Repo: {repoPath}
    - Branch base: {baseBranch}
    - Resume state: {fresh | resuming from {story-id}}
    - Execution model: inline — parent session executes each story directly; bounded helper sub-agents only.

    ## Applicable Policies (context lock)

    ### Company-scoped — {co} (hard + soft)
    1. **{policy-id}** [hard|soft] — {full rule text, verbatim}
    2. ...

    ### Repo-scoped — {repoPath} (hard + soft)
    1. ...

    ### Global hard-enforcement (filtered to run-project / execute-task / commit / deploy)
    1. ...

    > These rules are in force for every story below. Re-read before each story commit.

    ## Stories (approved execution order)

    ### 1. {story-id} — {title}
    - Type: {classification}
    - Advisory worker sequence: {architect → backend-dev → code-reviewer → qa} (reference only; parent executes directly; may spawn bounded sub-agents)
    - Files: {files[] or "undeclared"}
    - Acceptance criteria:
      - {AC 1}
      - {AC 2}
    - E2E tests: {e2eTests[] or "none"}
    - Linear issue: {linearIssueId or "none"}
    - Dependencies: {dependsOn or "none"}
    - Back-pressure gates: {tests / lint / typecheck / build / e2e from qualityGates}

    ### 2. ...

    ## Verification
    - Per-story: `git log --oneline -n {k}` shows expected commits; back-pressure gates pass; `prd.json` `passes: true` set.
    - Project-level: run `{qualityGates.command}` at end; regression sweep every 3 stories.
    - Linear sync: Done state on story pass (best-effort, non-blocking).

    ## Execution Rules (session-mode specific)

    1. Parent executes stories directly (Edit/Write/Bash). Do NOT spawn Task({subagent_type: "general-purpose", prompt: "/execute-task ..."}).
    2. Bounded helper sub-agents allowed for: code review, E2E/unit test run, design audit, accessibility check, read-heavy investigation, policy-specific verification. Must return structured JSON only.
    3. Commit per story before advancing — in the parent session.
    4. Re-read this plan file before each story to re-prime policy context.
    5. Pause after each story: ✓/✗ + files + commit SHA + back-pressure gates → continue / adjust / stop.
    6. Acquire `{repoPath}/.file-locks.json` entry per story; register in `workspace/orchestrator/active-runs.json`.

    ---

    <!-- session-mode-state -->
    ```json
    {
      "mode": "session-mode",
      "project": "{project}",
      "co": "{co}",
      "repoPath": "{repoPath}",
      "baseBranch": "{baseBranch}",
      "ordered_stories": [ { "id": "...", "title": "...", "files": [...], "branch": "...", "classification": "..." } ],
      "hard_policy_ids": [ "company:{id}", "repo:{id}", "global:{id}" ],
      "quality_gates": [ "..." ],
      "resume_from": null
    }
    ```

    No prose before/after. No raw PRD dumps. Just the plan body + state JSON.
  PROMPT
})
```

### Step S3 — Materialize Plan File

Parent receives the plan body and writes it verbatim to the Claude Code plan-mode file path (harness-provided — typically `~/.claude/plans/{slug}.md` for the current plan-mode session). If no plan-mode path is provided by the harness, use `~/.claude/plans/{project}-session.md`.

Plan file is the ONLY file the parent may write while plan mode is active — this matches Claude Code's plan-mode constraints.

### Step S4 — `ExitPlanMode`

Parent calls `ExitPlanMode`. User reviews the plan file (which now contains full policy rule text + story order + state JSON) and approves or requests edits. On edit requests, parent edits the plan file in place (still the only permitted write).

### Step S5 — Warm-Start

Runs after `ExitPlanMode` approval, before first story:
1. `/checkpoint` — write thread file capturing approved plan + policy set + story list
2. `/compact` — clear transcript

**Durability claim:** the plan file on disk is the sole durable context anchor. After compact, the parent re-reads it to rehydrate.

### Step S6 — Per-Story Execution Loop

For each incomplete story in plan order:

1. **Rehydrate.** Re-read the plan file's `## Stories` + `## Applicable Policies` sections (cheap — plan file stays 3-8K tokens).
2. **Announce.** Display story ID + title + advisory worker sequence (reference only).
3. **Branch + locks.** Create/checkout `branchName` from `baseBranch`; acquire `{repoPath}/.file-locks.json` entry for story `files[]`; register `workspace/orchestrator/active-runs.json`.
4. **Linear sync (best-effort).** Set In Progress.
5. **Execute directly in parent.** Use Edit / Write / Bash. Follow advisory worker sequence as a checklist:
   - Architect-equivalent: reason inline (no sub-agent)
   - Dev: apply edits directly
   - Reviewer: MAY spawn one-shot `general-purpose` sub-agent for code review on diff — returns JSON findings (≤1K tokens)
   - QA: MAY spawn one-shot sub-agent to run E2E/unit tests — returns `{pass, fail, log_tail}` JSON
6. **Back-pressure.** Run tests / lint / typecheck / build locally; fix in parent until green.
7. **Commit in parent.** No sub-agent commit delegation. Short commit message referencing story ID.
8. **Mark complete.** Set `passes: true` in prd.json; update state.json with commits + files_changed; Linear → Done (best-effort).
9. **Release locks.** Remove story entry from `.file-locks.json`; leave `active-runs.json` entry until completion.
10. **User checkpoint.** Display: `✓ {story-id} · {n} files · {commit-sha} · tests ✓ lint ✓ typecheck ✓` → continue / adjust / stop.
11. **Regression gate every 3 stories.** Run project-level `metadata.qualityGates` inline, or delegate to bounded QA sub-agent if the suite is heavy (returns `{passed, gate_results, failures}` JSON).

### Step S7 — Completion

1. Final summary to user: stories passed / failed / skipped + list of commits + Linear state.
2. **Archive plan file:** `mv ~/.claude/plans/{slug}.md workspace/orchestrator/{project}/session-mode-plan-{timestamp}.md` for audit trail.
3. Release `active-runs.json` entry.
4. Reindex: `qmd update 2>/dev/null || true`.
5. State → `status: "completed"` in state.json.

## Headless Bash Execution

Launch the bash orchestrator directly for long-running, unattended execution:

```bash
# Start or resume (auto-detected)
bash scripts/run-project.sh {project} --no-permissions

# Explicit resume
bash scripts/run-project.sh --resume {project} --no-permissions

# Dry run — show story order without executing
bash scripts/run-project.sh --dry-run {project}

# With options
bash scripts/run-project.sh {project} --model sonnet --no-permissions --verbose

# Check all project statuses
bash scripts/run-project.sh --status
```

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--resume` | auto-detected | Resume from next incomplete story |
| `--status` | — | Show all project statuses, exit |
| `--dry-run` | — | Show story order without executing |
| `--model MODEL` | (worker default) | Override model for all stories |
| `--no-permissions` | off | Pass `--dangerously-skip-permissions` to claude (auto-set in-session) |
| `--retry-failed` | off | Re-run previously failed stories only |
| `--timeout N` | none | Per-story wall-clock timeout in minutes |
| `--verbose` | off | Show full claude output |
| `--tmux` | off | Launch in tmux session with RC (observe from phone) |
| `--swarm [N]` | off (4) | Run eligible stories in parallel (max N concurrent) |
| `--checkin-interval N` | 180 | Seconds between check-in status prints |
| `--codex-autofix` | off | Auto-fix P1/P2 codex review findings (opt-in) |
| `--inline` | (default) | **Silent alias for default** — `/run-project {project}` and `/run-project {project} --inline` behave identically. Kept for back-compat |
| `--ralph-mode` | off | Opt into background orchestrator: `nohup bash scripts/run-project.sh {project}` + state-file polling. Each story runs as an isolated `claude -p` subprocess. Incompatible with `--inline` and `--session-mode` |
| `--session-mode` | off | Plan-file-anchored inline execution with full policy rule text distilled into `~/.claude/plans/{slug}.md`. Parent executes stories directly (no `/execute-task` sub-agent wrapper) |

## How It Works (Ralph Loop)

### Pre-Loop: Load Policies

Before entering the Ralph loop:

1. Read prd.json → extract `metadata.company` (or resolve from `metadata.repoPath` via manifest)
2. Load `companies/{co}/policies/` (skip `example-policy.md`) — read all
3. If `metadata.repoPath` set, check `{repoPath}/.claude/policies/` — read all
4. Load `.claude/policies/` — filter to policies with triggers relevant to "task execution", "deployment", "commit"
5. Pass applicable policy summaries to each `claude -p "/execute-task ..."` invocation context

Ensures orchestrator respects hard constraints (deploy safety, credential isolation) before delegating to execute-task.

### Task Selection (per iteration)

Selection order: **deps resolved → no file lock conflicts → lowest priority → array order**

1. Re-read PRD (sub-agent may have updated `passes`)
2. Filter: incomplete stories with all `dependsOn` satisfied
3. Filter: no file lock conflicts (checks `{repo}/.file-locks.json`)
4. Sort by `priority` field (lowest first)
5. First match = next task

### Per-Task Execution

For each selected story:

1. **PRE-TASK**: Branch setup (create/checkout `branchName` from `baseBranch`)
2. **PRE-TASK**: Linear sync → In Progress + comment (if `linearIssueId` configured)
3. **PRE-TASK**: Update `state.json` current_task
4. **EXECUTE**: `claude -p "/execute-task {project}/{story-id}"` as independent process
   - Model resolution: `--model` CLI flag > story `model_hint` > default
   - `/execute-task` handles: classification, worker selection, worker pipeline, PRD update, back pressure, learning capture
5. **POST-TASK**: Validate git state (auto-commit if sub-agent forgot)
6. **POST-TASK**: Codex CLI review safety net — `codex review` on latest changes (saved to `{story-id}.codex-review.md`). Flags critical issues. Best-effort, never blocks.
7. **POST-TASK**: Check `prd.json` `passes` field (source of truth)
8. **POST-TASK**: Linear sync → Done + comment (if configured)
9. **POST-TASK**: Update `state.json` + `progress.txt`
10. **POST-TASK**: `qmd update` reindex

### Regression Gates

Every 3 completed stories: run `metadata.qualityGates` commands from prd.json.
Interactive: retry/skip/pause/abort. Non-interactive: auto-pause on failure.

### Project Reanchor (Mid-Loop Spec Validation)

Every 3 completed stories (same cadence as regression gates), **after** the gate passes and **before** next task selection:

1. Re-read full prd.json — all stories, not just `passes`
2. Read `progress.txt` + recent `executions/*.output.json` + `executions/*.codex-review.md`
3. Evaluate remaining stories:
   - ACs still accurate given implemented work?
   - Did a completed story partially address a later story's work?
   - New required work discovered? (missing routes, data bugs from codex review)
   - Any story now unnecessary?
4. Write reanchor report: `workspace/orchestrator/{project}/reanchor-{n}.md`
5. **In-session (poll loop):** When Claude's poll detects a reanchor report file, surface it to user — apply suggestions / skip / review each
6. **Headless:** Write report, log summary, continue (never auto-modify PRD)

**Must NOT:** Auto-rewrite stories (breaks execute-task's "never rewrite PRD" invariant). Run per-story (too expensive). Block headless execution.

**Integration:**
- In-session loop: after regression gate block, read reanchor report, present to user
- Bash script: `run_project_reanchor()` spawns `claude -p` with reanchor prompt after `run_regression_gate()`

### Swarm Mode (`--swarm`)

When `--swarm [N]` is passed, the orchestrator dispatches eligible stories in parallel:

1. **Candidate selection**: `get_swarm_candidates()` finds stories with resolved deps, declared `files[]`, no file lock conflicts, and no pairwise file overlap
2. **Pre-acquire locks**: Orchestrator writes file locks BEFORE launching background processes (prevents race between concurrent execute-task lock acquisitions)
3. **Per-story worktrees**: Each story gets its own git worktree for branch isolation
4. **Background dispatch**: Each story launches as `claude -p` with `&`, tracked by PID
5. **Monitor loop**: Polls every 15s (`kill -0`), prints check-in status every `--checkin-interval` seconds
6. **Completion processing**: When a PID exits — validate git, codex review, orchestrator writes `passes`, update state
7. **Sequential merge**: Cherry-pick each worktree's commits into main project worktree (no conflicts since files don't overlap)
8. **Cleanup**: Remove worktrees, run regression gate if interval hit

Falls back to sequential for single candidates or stories without `files[]` declared.

**Safety**: Stories without `files[]` in prd.json are never swarmed (conservative — unknown file surface). The orchestrator (not execute-task) writes `passes: true` to prd.json, eliminating concurrent write races.

**Check-ins**: Both swarm and sequential modes print periodic status (story IDs, PIDs, elapsed time, output sizes).

**Config** (`settings/orchestrator.yaml`):
```yaml
swarm:
  max_concurrency: 4
  checkin_interval_seconds: 180
  require_files_declared: true
```

### Failure Handling

Interactive (terminal): retry / skip / pause / abort prompt.
Non-interactive (headless): auto-retry once, then skip to retry queue.
End-of-run: retry pass for all queued failures.

### Completion Flow

When all stories have `passes: true`:

1. **Board sync** → `done`
2. **Summary report** → `workspace/reports/{project}-summary.md`
3. **Doc sweep** — headless `claude -p` invocation updates 4 doc layers:

   a. **Internal docs** (team-facing: tech guides, SOPs, manuals, ontology, taxonomy)
      - `{repoPath}/docs/` or similar MDX dirs
      - New APIs, services, patterns, config not yet documented

   b. **External docs** (customer/vendor-facing documentation)
      - `{repoPath}/docs/` or published doc site
      - User-facing features needing doc updates. Skip if no external surface

   c. **Repo knowledge** (agent context)
      - `{repoPath}/.claude/CLAUDE.md`, `{repoPath}/.claude/policies/`
      - New patterns, gotchas, file locations from project execution

   d. **Company knowledge** (business knowledge)
      - `companies/{co}/knowledge/` — SEPARATE git repo, committed independently
      - Architecture, integration, process docs

   Output: `{execDir}/doc-sweep.output.json`. Non-blocking on failure.

3b. **Document release** — run `/document-release {company} {project}` (or headless `claude -p` with document-release skill).
    Runs the full document-release pipeline (diff analysis → doc audit → apply updates → consistency check → cleanup).
    Non-blocking on failure — log output to `{execDir}/doc-release.output.json`.

4. **INDEX.md** — flag for rebuild (deferred to `/cleanup`)
5. **Manifest verification** — check repos/workers registered
6. **qmd reindex** — final search index update
7. **State** → `status: "completed"`

State: `workspace/orchestrator/{project}/state.json` + `progress.txt`

## --status (in-session)

If $ARGUMENTS is `--status`:
1. Run `bash scripts/run-project.sh --status`
2. Display formatted output

## Rules

- **prd.json required** — never fall back to README.md
- **`passes` field is source of truth** — set by `/execute-task`, checked by orchestrator
- **Git validation after every story** — catches sub-agent commit failures
- **File lock awareness** — skip stories with locked files, try next candidate
- **Model hints** — story-level `model_hint` respected (CLI `--model` overrides)
- **Linear sync** — best-effort, never blocks execution
- **Regression gates** — `metadata.qualityGates` run every 3 stories
- **Resume is first-class** — auto-detected from state.json
- **Codex CLI mandatory** — at least one codex step (review or exec) required per code task. Sub-agent prompt enforces it; orchestrator runs fallback `codex review` post-task
- **Back pressure** — enforced inside `/execute-task`, not by orchestrator
- **Policy-aware** — load company + repo + global policies before first task. Hard-enforcement policies block the loop if violated
- **ALWAYS**: Use `"userStories"` key in prd.json (not `"stories"`) — `run-project.sh` greps for this exact key name
- **Default is inline (hard)** — a bare `/run-project {project}` executes stories in-session via per-story Task sub-agents. It does NOT launch `scripts/run-project.sh`. That requires `--ralph-mode`. Policy: `.claude/policies/run-project-default-is-inline.md`.
- **`--inline` is a silent alias for default** — no warning, no error, identical behavior
- **Default/inline isolation** — incompatible with `--ralph-mode`, `--session-mode`, `--swarm`, `--tmux`, `--codex-autofix` (error if combined)
- **Default/inline respects `--resume`** — skips completed stories, picks up from next incomplete
- **Default/inline uses Task/Agent tool** — worker sub-agents via Task tool (in-process), not `claude -p` (process isolation)
- **Default/inline preserves progress** — user can stop between stories; partial progress saved in prd.json + state.json
- **`--ralph-mode` launches `scripts/run-project.sh`** — the only execution path that spawns the background orchestrator. Stories run as isolated `claude -p` subprocesses; parent session polls `state.json`. Incompatible with `--inline` and `--session-mode`.
- **`--ralph-mode` implied by `--tmux`** — observing from phone requires the background orchestrator
- **Plan-mode preflight delegation (hard)** — when `/run-project` is invoked under Claude Code plan mode, the parent MUST NOT read prd.json, policies, or state.json directly. Spawn a `Plan` sub-agent to do the reads and return a condensed plan + JSON. Parent only ever holds the summary. This applies to all modes (default/inline, `--ralph-mode`, `--session-mode`). Rationale: plan mode defers compaction until after `ExitPlanMode` approval, so direct reads accumulate 10K+ tokens that linger across the entire execution run.

## Worked Example: Complete Project Execution (Ralph Loop)

This example shows `/run-project campaign-migration` executing through multiple stories, showing task selection, execution, regression gates, and completion.

### Scenario: Multi-Story Campaign Migration Project

**Project:** `campaign-migration` — Migrate 3 campaigns from legacy system to new platform.

**PRD State (at start):**
```json
{
  "name": "campaign-migration",
  "metadata": {
    "company": "{product}",
    "repoPath": "repos/private/{product}",
    "qualityGates": ["bun test", "bun check", "bun lint"]
  },
  "userStories": [
    {
      "id": "CM-001",
      "title": "Set up campaign database tables",
      "passes": false,
      "priority": 1,
      "dependsOn": []
    },
    {
      "id": "CM-002",
      "title": "Migrate campaign A data",
      "passes": false,
      "priority": 2,
      "dependsOn": ["CM-001"]
    },
    {
      "id": "CM-003",
      "title": "Migrate campaign B data",
      "passes": false,
      "priority": 2,
      "dependsOn": ["CM-001"]
    },
    {
      "id": "CM-004",
      "title": "Verify all campaigns migrated",
      "passes": false,
      "priority": 3,
      "dependsOn": ["CM-002", "CM-003"]
    }
  ]
}
```

### Start Execution

```bash
bash scripts/run-project.sh campaign-migration --no-permissions
```

### Iteration 1: CM-001 (Database Schema)

**Task Selection:**
```
Re-reading PRD...
Candidates: CM-001 (deps OK, priority 1), CM-002 (blocked on CM-001), CM-003 (blocked on CM-001)
Selected: CM-001 (lowest priority value)
```

**Execution:**
```
[1/4] Task: CM-001 - Set up campaign database tables
├─ Branch: checkout feature/cm-001 from main
├─ Linear sync: Issue CMG-1 → In Progress
├─ Command: claude -p "/execute-task campaign-migration/CM-001"
│  └─ Workers: [architect, database-dev, code-reviewer, codex-reviewer, dev-qa-tester]
│  └─ Phases: 5 completed (all passed)
├─ Post-task validation: git diff confirms 3 files modified
├─ Codex review: ✓ passed (no critical issues)
├─ Linear sync: Issue CMG-1 → Done
└─ Result: ✓ PASS (5 phases, 0 issues)

Updated PRD: CM-001 passes: true
Updated state.json: current_task = CM-001, status = completed
Updated progress.txt: [1/4] Complete
```

### Iteration 2: CM-002 (Campaign A Migration)

**Task Selection:**
```
Re-reading PRD...
Candidates: CM-002 (CM-001 done ✓), CM-003 (CM-001 done ✓)
Selected: CM-002 (priority 2, first in array order)
```

**Execution:**
```
[2/4] Task: CM-002 - Migrate campaign A data
├─ Branch: checkout feature/cm-002 from main
├─ Linear sync: Issue CMG-2 → In Progress
├─ Command: claude -p "/execute-task campaign-migration/CM-002"
│  └─ Workers: [backend-dev, code-reviewer, codex-reviewer, dev-qa-tester]
│  └─ Phases: 4 completed (all passed)
├─ Post-task validation: git diff confirms 2 files modified, 1 migration created
├─ Codex review: ✓ passed
├─ Linear sync: Issue CMG-2 → Done
└─ Result: ✓ PASS (4 phases, 0 issues)

Updated PRD: CM-002 passes: true
Progress: [2/4] Complete
```

### Iteration 3: CM-003 (Campaign B Migration)

**Task Selection:**
```
Re-reading PRD...
Candidates: CM-003 (CM-001 done ✓, CM-002 independent)
Selected: CM-003 (priority 2, available)
```

**Execution:**
```
[3/4] Task: CM-003 - Migrate campaign B data
├─ Branch: checkout feature/cm-003 from main
├─ Linear sync: Issue CMG-3 → In Progress
├─ Command: claude -p "/execute-task campaign-migration/CM-003"
│  └─ Workers: [backend-dev, code-reviewer, codex-reviewer, dev-qa-tester]
│  └─ Phases: 4 completed (all passed)
├─ Post-task validation: git diff confirms 2 files modified, 1 migration created
├─ Codex review: ✓ passed
├─ Linear sync: Issue CMG-3 → Done
└─ Result: ✓ PASS (4 phases, 0 issues)

Updated PRD: CM-003 passes: true
Progress: [3/4] Complete

>>> REGRESSION GATE: Every 3 stories complete, run quality gates
Running: bun test, bun check, bun lint
├─ bun test: 127 passed, 0 failed ✓
├─ bun check: 0 TypeScript errors ✓
├─ bun lint: 0 issues ✓
Result: ✓ ALL GATES PASSED
```

### Iteration 4: CM-004 (Verification)

**Task Selection:**
```
Re-reading PRD...
Candidates: CM-004 (CM-002 done ✓, CM-003 done ✓)
Selected: CM-004 (all deps satisfied)
```

**Execution:**
```
[4/4] Task: CM-004 - Verify all campaigns migrated
├─ Branch: checkout feature/cm-004 from main
├─ Linear sync: Issue CMG-4 → In Progress
├─ Command: claude -p "/execute-task campaign-migration/CM-004"
│  └─ Workers: [dev-qa-tester, code-reviewer]
│  └─ Phases: 2 completed (all passed)
├─ Post-task validation: git status clean
├─ Codex review: ✓ passed
├─ Linear sync: Issue CMG-4 → Done
└─ Result: ✓ PASS (2 phases, 0 issues)

Updated PRD: CM-004 passes: true
Progress: [4/4] Complete
```

### Completion Flow

**All Stories Complete:**
```
✓ CM-001: Set up campaign database tables
✓ CM-002: Migrate campaign A data
✓ CM-003: Migrate campaign B data
✓ CM-004: Verify all campaigns migrated

Running completion flow...
├─ Linear board sync: Project → done state
├─ Generate summary report: workspace/reports/campaign-migration-summary.md
├─ INDEX.md flagged for rebuild (deferred to /cleanup)
├─ Manifest verification: ✓ all repos registered
├─ Final reindex: qmd update
└─ State: status → completed

Completion Summary:
╔═══════════════════════════════════════════════════════╗
║  campaign-migration: ALL 4 STORIES COMPLETE          ║
╠═══════════════════════════════════════════════════════╣
║  Started: 2026-03-08 14:15 UTC                       ║
║  Completed: 2026-03-08 16:47 UTC (2h 32m)            ║
║  Total phases: 15                                    ║
║  Total workers: 6 unique workers                     ║
║  Back pressure: 15/15 phases passed ✓                ║
║  Regression gates: 2/2 passed ✓                      ║
╚═══════════════════════════════════════════════════════╝

Report saved: workspace/reports/campaign-migration-summary.md
State saved: workspace/orchestrator/campaign-migration/state.json
Progress: workspace/orchestrator/campaign-migration/progress.txt

Next step: /run-project --status to see all projects
```

### Summary Output

The orchestrator stores execution metadata at:
- **State:** `workspace/orchestrator/campaign-migration/state.json`
- **Progress:** `workspace/orchestrator/campaign-migration/progress.txt`
- **Report:** `workspace/reports/campaign-migration-summary.md`

**progress.txt:**
```
campaign-migration: 4/4 complete
[✓] CM-001: Set up campaign database tables
[✓] CM-002: Migrate campaign A data
[✓] CM-003: Migrate campaign B data
[✓] CM-004: Verify all campaigns migrated

Regression gates: 2/2 passed
Last updated: 2026-03-08 16:47:33 UTC
```

**state.json (final):**
```json
{
  "project": "campaign-migration",
  "status": "completed",
  "started_at": "2026-03-08T14:15:00Z",
  "completed_at": "2026-03-08T16:47:33Z",
  "stories_total": 4,
  "stories_completed": 4,
  "stories_failed": 0,
  "current_task": null,
  "phases_total": 15,
  "phases_completed": 15,
  "regressions_run": 2,
  "regressions_passed": 2
}
```

---

## Integration

- `/plan` → creates PRD → `/run-project {name}` executes it
- `/execute-task {project}/{id}` → runs single task (standalone or headless)
- `/run-project --resume` → continues from next incomplete story
- `/nexttask` → shows active projects
