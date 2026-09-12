---
name: run-project
description: Router for executing HQ PRD stories. Default dispatches each story as a detached workflow-runner lane — the same mechanism /conduct uses — into a pooled per-worker slot claimed through conduct-pool.sh, so work in flight survives session compaction and can be corrected mid-flight (the coordinator loop stays parent-side, so a lost session leaves the run resumable, not self-advancing). Typically 3-4 live lanes (preflight explorer, story worker, regression gate), never more than CONDUCT_POOL_CAP (default 8), regardless of how many stories the PRD holds. In-session spawn_agent is the fallback for a host with no engine CLI; explicit interactive mode runs directly in the parent and takes no pool slots; Ralph/headless runs the same pooled lane loop unattended (auto-advance, no pauses).
allowed-tools: Read, spawn_agent, wait_agent, Bash(bash core/scripts/conduct-pool.sh:*), Bash(bash core/scripts/conduct-inbox.sh:*), Bash(bash core/scripts/hq-session.sh:*), Bash(node core/scripts/workflow-runner.mjs:*), Bash(setsid:*), Bash(ps:*), Bash(grep:*), Bash(bash:*), Bash(jq:*), Bash(cat:*), Bash(tail:*), Bash(kill:*), Bash(ls:*), Bash(mkdir:*), Bash(echo:*), Bash(sleep:*), Bash(qmd:*), Bash(test:*), Bash(bash core/scripts/work-mesh-live-bind-trusted.sh:*), Bash, Write, AskUserQuestion, Task
argument-hint: "{project} [--status] [--resume] [--dry-run] [--inline] [--interactive] [--ralph-mode] [--in-place] [--timeout N]"
---

# Run Project — Codex Router

Codex does not use Claude Code's `Task`, `Plan` sub-agents, `ExitPlanMode`, `/checkpoint`, or `/compact` primitives. The default path needs none of them: every story is a detached lane. Where a host has no engine CLI and falls back in-session, Codex's `spawn_agent` / `wait_agent` map the per-story boundary to a `worker` agent and the read-only preflight to an `explorer` agent.

**Live children: typical 3–4, worst case `CONDUCT_POOL_CAP` (default 8).** Every
agent this skill dispatches is a pooled lane claimed through
`core/scripts/conduct-pool.sh` and dispatched as a detached process per
`.claude/skills/_shared/lane-dispatch-protocol.md`, so the count is set by the
pool, not by the number of stories — a 40-story PRD opens no more lanes than a
4-story one.
Story coordinators claim `story:{worker-id}`; the phases inside them claim the
bare worker id, so a story can never block on a lane it is holding itself.
`--interactive` runs in the parent and claims none.

**User's input:** $ARGUMENTS

## Script Resolution

Resolve the shell orchestrator before any shell delegation:

1. Prefer `core/scripts/run-project.sh` if it exists.
2. Otherwise use `.claude/scripts/run-project.sh`.
3. If neither exists, stop with a clear error.

Store the chosen path as `{run_project_script}`. In this HQ workspace today, the expected path is `.claude/scripts/run-project.sh`.

## Work Mesh Live — trusted bind (do this first)

Before any other tool call that touches project work, bind the session per
`.claude/skills/_shared/work-mesh-live-bind.md` (US-011):

```bash
bash core/scripts/work-mesh-live-bind-trusted.sh \
  --company "{co}" --project "{project}" --task "{task}"
```

Omit `--task` when unknown. This writes `workspace/sessions/<sid>/meta.yaml`
and reconciles with `observation.trustedContext` (no `--trusted` CLI flag).

## Step 1 — Parse Arguments

Extract from `$ARGUMENTS`:

- `{project}` — project name, required unless `--status` or `--help`
- `--status` — show orchestrator status, then stop
- `--dry-run` — show story order, then stop
- `--resume` — pass through to the chosen execution path
- `--inline` — the default: one detached lane per story, pooled (Step 3). The name is historical; it means *story-delegated*, as opposed to `--interactive`'s parent-driven editing. It has not meant "in the parent session" since stories became lanes.
- `--interactive` or `--session-mode` — parent-driven Codex execution
- `--ralph-mode` — the same pooled lane loop as default, run unattended: skip the preflight approval, auto-advance through every story without between-story pauses, and report once at the end
- `--in-place` — (ralph) skip feature-branch pre-creation; work on the current checkout
- `--timeout N` — (ralph) per-story wall-clock budget in minutes before a story is marked `blocked: TIMEOUT`. This is the waiter's `deadline` file (dispatch protocol §4-§5), not the runner's `timeoutSecs` — that one only warns and never kills, so it cannot bound anything on its own.
- `--resume` continues from the next incomplete story (read from `state.json`)

If no execution mode is supplied, route to `--inline`. This is the default because it preserves the Ralph story loop and keeps implementation context out of the parent session — each story runs in its own detached lane, so the parent holds coordination state only.

Use `--interactive` only when the user asks to steer edits directly in the parent session; it is the one mode that does not dispatch lanes at all. Use `--ralph-mode` for long unattended runs where you do not want to be prompted between stories — it executes the identical worker-authoritative lane loop, just without the pauses.

**Recommendation posture:** always recommend `--inline`. It runs **continuously — no pause between stories** — except when either condition holds:

1. The PRD has **more than 10 incomplete stories** → pause at the preflight plan for one approval, then run continuously.
2. A story **requires session mode** (its notes or classification demand parent-driven interactive steering) → pause before that story only, run it interactively, then resume continuous flow.

Everything else auto-continues exactly like ralph-mode. Failed or blocked stories still stop the queue.

> **Note on the legacy detached orchestrator — not the same thing as a lane.** Earlier versions of this skill launched a detached shell subprocess (`nohup bash run-project.sh … --engine claude`) that ran one headless `claude -p` builder per story, outside the pool and outside the worker system. *That* path is retired: `run-project.sh`'s execution loop is frozen and kept only for `--status`, `--dry-run`, and `--help`; it no longer runs stories, and it has no `claude` builder. The `--engine`/`--builder`, `--swarm`, `--tmux`, `--codex-autofix`, and `--no-monitor` flags belonged to it and are not accepted.
>
> Today's lanes are a different mechanism and share none of that: they are pooled, capped by `CONDUCT_POOL_CAP`, worker-authoritative, engine-chosen from the dispatch protocol's roster, and each one runs `/execute-task` rather than a bare headless builder. "Detached" describes both, which is why this note exists — do not read the retirement above as a claim that stories run in the parent session.

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

## Step 3 — Default Execution: Pooled, Detached Lanes

Default mode is story-delegated, **pooled**, and **detached**. The parent session
plans and coordinates; each story runs in a lane claimed from the session pool —
one live lane per HQ worker id, reused across stories rather than a fresh child
per story — that invokes `/execute-task {project}/{story-id}` internally.

**A lane is a detached OS process, not an in-session sub-agent.** Dispatch
follows `.claude/skills/_shared/lane-dispatch-protocol.md`, the same mechanism
`/conduct` uses: a brief on disk, a `setsid` `workflow-runner.mjs` process, and a
background waiter. Three things follow from that, and they are the reason this is
the default:

- **Work in flight survives the parent session.** Compaction, a restart, or an
  ended session no longer kills the running story — the previous in-session
  loop died with its parent, mid-story, with the slot still marked running and
  the work lost. Be precise about the scope: the *story* survives, the
  *coordinator* does not. The waiter, the validation and the dispatch of the
  next story are all parent-side, so a run that loses its session finishes the
  in-flight story and then waits for a new session to resume it (Step 5). It is
  resumable, not self-driving.
- A story can be **corrected while it runs** (dispatch protocol §6) instead of
  being killed and relaunched.
- A host with **no in-session sub-agent primitive** can still run a project.

Inside the lane, `/execute-task` maps its worker phases to that engine's own
sub-agents (`spawn_agent` under Codex, `Task` under Claude) per
`.claude/skills/execute-task/SKILL.md`. Those phases are children of the lane, not
of this session, and they claim their bare-worker-id slots from the **same** pool
— which is why the lane must carry `HQ_SESSION_ID` (dispatch protocol §4).

**Resolve the engine once, before the first dispatch** (dispatch protocol §2):
an engine the user named, else `codex`, else the first of `grok`/`claude` that
resolves. Record it in `workspace/orchestrator/{project}/state.json` and reuse it
for the preflight, every story, and the regression gate.

**Record the session id next to it, in the same write.** Both the pool and the
run dirs are keyed by the session that created them: `conduct-pool.sh` resolves
the session from the environment, and the protocol mints run dirs under the
session id (dispatch protocol §3). A later session therefore looks in *its
own* pool, finds nothing, and concludes the run has no live lanes — while the
original slots are still `running` and the original lane is still committing.
That is how a story gets dispatched twice. So:

So write two fields, not one: `engine`, and `session_id` set to the output of
`bash core/scripts/hq-session.sh current`. Use `jq` and a temp file rather than
editing the JSON in place.

Write `session_id` before the first dispatch, and never overwrite it on a
resume — it names the session that owns the lanes, not the session reading the
file. Re-resolving per lane
gives a run whose stories ran on different models — results that are not
comparable and a failure you cannot attribute. `/run-project` takes no
`--engine` flag; that flag belonged to the retired subprocess loop.

**Fallback — no engine CLI.** If no `codex`/`grok`/`claude` CLI resolves, detached lanes are
unavailable on this host: say so plainly, then run the story loop in-session with
`spawn_agent`/`wait_agent` (or `Task`) exactly as described in 3b's fallback note.
Everything else in this step — the pool claim, the return contract, the retry, the
proof gates — is identical on both paths. Do not discover a missing engine once
per story.

### 3a. Preflight Plan

The preflight explorer is a **named pool slot**, not a throwaway. Claim and
validate it exactly as `.claude/skills/_shared/pool-lane-protocol.md` describes
— `assign`, honour exits 3 and 4, `mkdir -p` the slot dir, check `owner.json`
before the spawn/resume split, and `record` running immediately after launch — a
lane left `claimed` while work is live is one `cancel` may retire as undispatched
(pool protocol §4):

```bash
bash core/scripts/conduct-pool.sh assign --worker-id "explorer" --task "{project} preflight"
```

The ownership check is not optional here just because the id is a constant — it
is *more* necessary. `explorer` is the same lane id for every project and every
company, so a second `/run-project` in one session resumes the first one's
planning transcript unless the stamp is checked. On a company or project
mismatch: `cancel` (not `recycle` — nothing has been dispatched into this claim
yet), clear, re-stamp, dispatch cold. Then:

Dispatch it as a lane per `.claude/skills/_shared/lane-dispatch-protocol.md`
(`{caller}` = `run-project`, `{lane}` = `explorer` — the protocol mints the run
dir; do not spell one here — **`{tier}` = `plan`** — this is analysis, not execution, and the
protocol's tier is a caller-supplied placeholder precisely so this lane does not
inherit `exec`). The brief:

```
Read and analyze the PRD for {project}. Resolve prd.json, identify incomplete
userStories, sort by dependencies then priority then array order, classify each
story using /execute-task rules, identify worker sequences, read applicable hard
policy rules, and return only a concise markdown implementation plan followed by
a JSON block with project, company, repoPath, ordered_stories, hard_policies,
quality_gates, and resume_from.
```

Wait on it with the protocol's background waiter, then read the plan out of
`agent-1.result.json` per protocol §7 — `jq -r '.value'`, never `lane.log`, which
also carries the runner's narration. On the no-engine fallback, the same brief goes to
`spawn_agent({agent_type: "explorer", reasoning_effort: "low", …})` +
`wait_agent(...)` instead.

Display the plan. If the queue has **≤10 incomplete stories and none require session mode**, proceed directly into the story loop without an approval stop. Otherwise (>10 stories, or session-mode stories present) ask the user to approve, adjust, switch to `--interactive`, switch to `--ralph-mode`, or stop. If structured question tooling is unavailable, use the plain-text fallback required by `core/policies/hq-codex-decision-gate-fallback.md`.

### 3b. Story Loop

For each approved incomplete story:

1. Announce story ID, title, and planned worker sequence.
2. Perform only lightweight parent orchestration: branch setup, state file update, and best-effort Linear sync.
3. Claim the story worker's lane, then dispatch into it. Classify the story to
   an HQ worker id first (same classification `/execute-task` uses), then:

   ```bash
   bash core/scripts/conduct-pool.sh assign \
     --worker-id "story:{worker-id}" --task "{project}/{story-id}"
   ```

   **The `story:` prefix is not cosmetic.** This wrapper does no domain work; it
   runs `/execute-task`, whose phases claim the **bare** worker id in their own
   `assign`. A wrapper holding `backend-dev` would send its own
   `api_development` phase to exit 4 — waiting for a lane the wrapper itself is
   holding, with the wrapper waiting on that phase. Neither ever finishes.
   Coordinator lanes live in the `story:` namespace; phase lanes use the bare
   id; they can never collide. The delimiter is a colon, not a slash:
   `conduct-pool.sh` restricts worker ids to `[A-Za-z0-9._:-]`, so
   `story/backend-dev` exits 1 and no coordinator lane is claimed at all.

   Then follow `.claude/skills/_shared/pool-lane-protocol.md` for the slot —
   the exit codes (3 and 4 both mean **wait**), the `mkdir -p` and `owner.json`
   check before the spawn/resume split — and
   `.claude/skills/_shared/lane-dispatch-protocol.md` for the dispatch itself.
   `record --status running` against the run-dir basename immediately after
   launch; a lane left `claimed` while work is live is one `cancel` may retire as
   undispatched (pool protocol §4). `record … --status idle` the moment the lane
   exits — **before** reading its JSON and before deciding whether to retry. Step
   3b.4's one retry on malformed JSON re-dispatches through `assign`, so a lane
   released only after the JSON validates sends exactly that retry to exit 4,
   waiting on a coordinator that has already finished.

   `{caller}` = `run-project`, `{lane}` = `{story-id}` — the protocol mints the
   run dir, session-scoped and collision-free; do not spell a path here. Pool
   lane id: `story:{worker-id}`. `{tier}` = `exec`. `deadline` = now + the
   per-story budget (`--timeout N` minutes, default 20). The brief is the prompt
   below.

   `{"action":"spawn",...}` means dispatch a fresh lane with the full prompt.

   `{"action":"resume",...}` means that coordinator already has an idle lane
   holding everything it learned on earlier stories of this class. **A lane is a
   process that has already exited — there is nothing to reattach to — so do not
   treat this branch as unimplementable and do not leave it.** A coordinator that
   cannot act on a `resume` leaves the slot stuck and every later claim for that
   worker exits 4. Use the pool protocol's disk-backed restart: dispatch a new
   lane into the **same slot**, with the full prompt below prefixed by

   ```
   You are resuming your own lane. Every story you already ran in this session is
   recorded in {slot dir}/handoffs.jsonl — read it first and do not redo anything
   it shows as done. That file belongs to this session and this company only; if
   it is absent, start from the brief.
   ```

   then `record` the new run-dir basename against the **same** slot. The cap
   counts slots, not restarts. Append each validated story JSON to that file so
   the next restart can see it.

   Two stories that classify to the same worker id share one coordinator lane
   and therefore **serialize** on it. That is the intended behaviour, not a
   stall — their phases would have serialized on the bare worker lane anyway.

The brief written to the lane's `brief.md` (on the no-engine fallback, the same
text is the `message:` of `spawn_agent({agent_type: "worker", reasoning_effort:
"low", …})` followed by `wait_agent(...)`):

```
Execute story {project}/{story-id} by running /execute-task {project}/{story-id}.

You are not alone in the codebase. Own only this story and its declared files;
do not revert edits made by others; adapt to existing changes you encounter.

When /execute-task asks for a sub-agent, use your engine's own runtime adapter so
the nested HQ worker phases run as isolated agents inside this lane. They claim
their phase slots from the same session pool this lane was granted from.

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
  "evidence": ["repo-path:src/lib/foo.ts", "path:companies/{co}/projects/{project}/report.md", "url:https://...", ...],
  "notes": "<1-2 sentence summary; include blocker description if status != passed>"
}
"evidence" lists what you actually produced, in these forms: path:<hq-relative> ·
repo-path:<relative to the repo> · branch:<name> · url:<https://…>. Commits go
in "commits" and count as evidence automatically. List only things that exist —
every item is verified on disk/git before the story is marked done, and a claim
that does not exist fails the story. An empty list is allowed.
```

Arm the protocol's background waiter on the lane. The story's JSON arrives in the
run dir, not as a tool return, and **not in `lane.log`** — read it per protocol
§7:

```bash
raw="$(jq -r '.value' "{run dir}/agent-1.result.json")"   # unwrap the runner envelope
printf '%s' "$raw" | jq -e '.status, .workers_run, .evidence'
```

`lane.log` is the runner's whole stdout — narration plus
`JSON.stringify(result)`, and because the story worker is schema-less that
result is a JSON *string* holding the story JSON. `jq -e .` against `lane.log`
therefore **passes** while `.status`, `.workers_run`, and `.evidence` all come
back empty, so step 4 would wave through a story it never actually read and
step 5's worker-proof gate would reject a worker that did run its phases. Two
`jq` calls, on `agent-1.result.json`, not one on the log.

4. Validate `$raw` — the unwrapped value, not the log — as JSON with `jq -e .` (or equivalent). If invalid, retry exactly once with this stricter prompt addition: `Your previous reply was not valid JSON. Emit ONLY the JSON object specified above. No prose, no fences, no trailing newline.` If still invalid, mark the story `blocked` with reason `INVALID_RETURN_FORMAT`, surface to user, do NOT advance to the next story. (Enforced by [ralph-orchestrator-context-discipline](../../../core/policies/ralph-orchestrator-context-discipline.md).)
5. Enforce the worker proof gate: passed stories must include at least one real HQ worker ID in `workers_run`; reject placeholder-only values like `codex`, `worker`, `general-purpose`, or `commit`.
6. Verify commits are parent-visible with `git log --oneline -n {len(commits)}`. If the worker produced an integration patch instead of a visible commit, review/integrate it in the parent and create the story commit before continuing.
7. Verify the worker's evidence and mark the story. Run
   `bash core/scripts/verify-story-deliverables.sh --prd <prd.json> --story <id> [--repo <repoPath>] --evidence-json '<reply.evidence>' --commits-json '<reply.commits>' --write`.
   Exit 0 records the verified references on the story as `evidence[]` (audit trail) and you may write `passes: true`. Exit 3 names what does not exist — a claimed path/branch/commit/URL that is missing, or a deliverable the PRD declared that was never produced — and the story is NOT done: do not write the flag, treat it like a failed back-pressure check. A worker that returns no evidence and a PRD that declares none is allowed (the story is marked done but unverified); this gate is deliberately not strict.
   Mark `passes: true` only after status is `passed`, worker proof passes, back-pressure is acceptable, commit verification succeeds, and this evidence check exits 0.
8. Update `workspace/orchestrator/{project}/state.json`. Record the story's run
   dir on the story entry as you dispatch it, not after it returns — a run that
   loses its session mid-story is exactly the case where the path is needed, and
   it is the only record of which lane belongs to which story.
9. Narrate one line per story to the user: `[{story_id}] {status} · {files_changed} files · {first_commit_short_sha}`. Anything longer goes to `workspace/threads/journal/<date>/<story-id>.md`, not the parent transcript.
10. Auto-continue to the next incomplete story until the queue is empty or a story is `failed`/`blocked` (then surface and stop). Pause only per the recommendation-posture exceptions in Step 1: >10 incomplete stories (single preflight approval) or a story that requires session mode (pause before that story only).

### 3c. Regression Gates

Every 3 completed stories, run budget-aware `metadata.qualityGates` in the **regression-gate pool slot** — `conduct-pool.sh assign --worker-id "regression-gate"`, resumed at every gate rather than respawned — dispatched as a lane per `.claude/skills/_shared/lane-dispatch-protocol.md` (`{tier}` = `exec`), and require compact JSON — read back through `jq -r '.value' {run dir}/agent-1.result.json` per protocol §7, not from `lane.log`. A resumed gate lane already knows which repos it checked last time, which is what makes "repos touched since the last gate" cheap. `regression-gate` is another constant id shared across every project, so run the same `owner.json` check from `.claude/skills/_shared/pool-lane-protocol.md` before resuming it; a gate lane carrying another company's repo list is both a wrong answer and a leak. Default to gates for repos touched since the last gate; run the full matrix at final completion, before deploy, after high-risk cross-repo contract changes, or when explicitly requested. Capture detailed logs to files and keep the parent transcript to the compact return:

```json
{"passed": true, "scope": "changed-repos", "gate_results": {"<gate>": "pass"}, "failures": []}
```

On failure, surface the summary and ask whether to fix, adjust, stop, or switch to Ralph/headless mode.

**Two regression layers, do not conflate them.** This every-3-stories quality gate is the *coarse* layer. The *fine* layer runs inside every story: when a story has non-empty `e2eTests`, `/execute-task`'s acceptance-test-writer phase writes `{repo}/__tests__/stories/{id}.test.ts` and then runs the **entire** `__tests__/stories/` suite as back-pressure — so every story re-verifies all prior stories' acceptance criteria and a regression (story N breaking story A) is caught immediately, not up to 3 stories later. A failing prior-story test is a back-pressure failure for the current story (the worker returns `all_story_tests_pass: false`). The orchestrator does not need to schedule this — it is part of the story worker's contract — but must treat such a story as not `passed`.

### 3d. Budget Guardrails

- Every agent this skill dispatches comes from the session pool and follows `.claude/skills/_shared/pool-lane-protocol.md`: the preflight explorer, each story's coordinator lane, and the regression gate are **named slots that resume**, not new children per story. All three are ownership-checked before reuse — `explorer` and `regression-gate` are constant ids shared across every project and company, so they are the lanes most likely to hand one tenant's context to another. Typical run: 3-4 live lanes. Hard ceiling: `CONDUCT_POOL_CAP` (default 8), enforced by `conduct-pool.sh assign`, and it does not move with the story count.
- **A coordinator lane holds a slot while its phases need one, so concurrency has to leave them room** (protocol §7). Run at most `max(1, (CONDUCT_POOL_CAP - 2) / 2)` stories concurrently — **3 at the default cap of 8**. At a cap of 2 or 3 the reserved explorer/gate pair is what does not fit: recycle those slots once used and run one coordinator serially. At a cap of 1, nested execution is impossible — say so and stop, offering a higher cap or `--interactive`. The `- 2` is the explorer and regression-gate slots, which stay claimed as `idle` and still count; the `/ 2` guarantees every live coordinator can still claim the one phase lane it needs. Exceed it and the pool fills with coordinators that are each waiting on a phase lane that can no longer be granted — exit 3 for everyone, forever, with nothing running that could release a slot.
- Leave a slot `idle`, never `running`, as soon as its lane exits — before validating the reply, per pool protocol §6. A slot stuck `running` makes every later `assign` for that worker exit 4 and stalls the queue.
- **A detached lane outlives a failed parent turn.** If the parent is interrupted between launch and release, the slot stays `running` with a real process behind it. That is recoverable, not corrupt: `conduct-pool.sh list` names the run dir, the run dir says whether the lane finished, and only then is `recycle --force` correct. Never force-retire a slot you have not checked the run dir for.
- When a lane's context grows fat — many stories on one worker, or a return that shows it losing earlier detail — compact or recycle that slot. Do not open a second lane for the same worker to escape it.
- Do not simulate `/execute-task` by spawning worker-phase agents from the parent. If the story worker cannot run `/execute-task`, pause and switch modes.
- **Swarm only as far as the pool allows.** When incomplete stories are mutually independent (no dependency edges, no overlapping declared files) **and classify to different worker ids**, dispatch them concurrently — but only up to the concurrent-story limit above, and only on lanes `assign` actually granted. Independent stories that share a worker id serialize on that one lane. Validate each returned JSON, worker proof, and commit per story as replies arrive; run the regression gate after the batch. Stories with dependencies or file overlap still run sequentially. A second lane for a worker that already has one, or an extra review or QA agent beyond the story workers, still requires a high-risk trigger or explicit user opt-in after naming the cost.
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
   - mark `passes: true` only after verification (worker proof, commits, and the evidence check `verify-story-deliverables.sh --evidence-json … --commits-json … --write` exit 0)
   - do not claim `workers_run` or worker-backed completion unless `/execute-task` actually ran through the worker system
   - update `workspace/orchestrator/{project}/state.json`
6. Pause between stories and ask continue / adjust / stop.

Do not spawn an end-to-end `/execute-task` sub-agent in Codex interactive mode unless the user explicitly asks for delegated agent work. Bounded helper agents are okay only when explicitly requested or clearly available, and they must return compact structured output.

## Step 5 — Ralph/Headless Unattended Execution

Use when the project is long-running and the user wants it to run to completion without being prompted between stories.

Ralph/headless is **the same pooled, detached story loop as Step 3, run unattended.** Same lanes, same pool, same return contract; it differs only in that it does not pause.

**What detachment does and does not buy here — say this plainly, because the
difference matters to anyone leaving a run going.** The *stories* are detached:
the in-flight one keeps running and keeps committing when the parent session
ends, where the previous in-session loop died with its parent mid-story. The
*coordinator* is not. The waiter, the result validation, the slot release and
the decision to dispatch the next story all live in the parent. So a session
that ends mid-run leaves exactly one story running to completion and then
stops — it does not auto-advance to story N+1 unattended. "Unattended" here
means no prompts between stories **within a session**, not a run that drives
itself after the session is gone.

That makes the run *resumable*, not *self-driving*, and resuming takes a new
session: `conduct-pool.sh list` names the live slots and their run dirs, and
`state.json` says which stories are done. A genuinely self-driving run would
need the loop itself dispatched as a lane — an extra coordinator level with its
own pool accounting — which does not exist today. Do not tell a user their run
will finish on its own after they close the session.

**5.0 — Pre-flight (run ONCE, before the loop starts).** Skipping the *approval pause* (operational step 1 below) must not skip *validation*. Before auto-advancing, the orchestrator must:

1. **Pre-create the feature branch** from `metadata.baseBranch` unless `--in-place` was passed — never let an unattended run discover mid-loop that it has been committing to the wrong branch (`run-project-precreate-branch-before-ralph`).
2. **Scan the PRD for stories whose acceptance requires interactive input** (a decision the worker would surface via `AskUserQuestion`) and mark them `blocked` up front with reason `NEEDS_INTERACTION` — do not let them wedge the loop mid-run (`hq-cmd-run-project-no-askuserquestion-stories-in-ralph-mode`). Workers in ralph mode never call `AskUserQuestion`.
3. **Verify the target repo + branch resolve and the tree is clean.** Abort with a clear message if not — an unattended run on a dirty or missing tree is never correct.

If any pre-flight check cannot be satisfied, stop and surface it; do not start the loop.

The operational differences from default inline are then:

1. **Skip the preflight approval gate (Step 3a).** Still run the preflight explorer slot to build the plan (claimed or resumed the same way), but do not pause for approval — log the plan to `workspace/orchestrator/{project}/codex-session-plan.md` and proceed.
2. **Auto-advance.** Run the Step 3b story loop for every approved incomplete story back to back. Do not pause between stories (Step 3b.10 already auto-advances; ralph-mode also skips the >10-story and session-mode pauses). All per-story invariants still hold: JSON-validate the worker return, enforce the worker-proof gate, verify parent-visible commits, mark `passes: true` only after verification, and update `state.json` after each story.
3. **Run regression gates on cadence.** Apply Step 3c every 3 completed stories exactly as in inline mode.
4. **Report once.** Emit one compact line per story to the transcript (`[{story_id}] {status} · {files_changed} files · {first_commit_short_sha}`); send anything longer to `workspace/threads/journal/<date>/<story-id>.md`. Surface a single summary at the end rather than pausing throughout.
5. **Bound wedge time.** A lane that never returns must not stall the run forever. Set the waiter's `deadline` file from the per-story budget (default ~20 min; honor `--timeout N` minutes if passed) — **not** the runner's `timeoutSecs`, which only prints a repeating warning and never kills, so on its own it bounds nothing and the waiter would loop for a `CONDUCT_EXIT` marker that never arrives. When the waiter returns `outcome: deadline`, the lane is **still running**: ask the runner to stop and wait for its `CONDUCT_EXIT` marker (dispatch protocol §5 — signalling the wrapper group never reaches the engine, which the runner spawns detached into a group of its own). Mark the story `blocked` with reason `TIMEOUT`, stop, and surface it either way. Retire the slot with `recycle --force` **only if the lane stopped cleanly and §5's confirmation reported `engine_gone=yes`** — that confirmation runs on every outcome, not just this one, so a `died` or `never-started` lane with a surviving engine group is held back the same way; if the marker never arrived or the group still has members, leave the slot `running`, say the engine may still be live, and let the user decide — reusing an unconfirmed slot puts the next worker in a lane the old one is still writing to. Do not silently move on. Slow back-pressure (e.g. heavy E2E) is the usual cause.

Stop and surface to the user mid-run only on a hard blocker: a story that lands `blocked` (including `INVALID_RETURN_FORMAT`, `NEEDS_INTERACTION`, or `TIMEOUT`), a failed regression gate (coarse 3-story gate or a per-story `all_story_tests_pass: false`), or a worker that cannot run `/execute-task`. Do not silently skip past a blocked story to the next one — auto-advance applies to *passed* stories only.

Every story lane has a PID, a run dir, and a `lane.log`, so **a new session** can pick the run back up — nothing picks itself back up.

**Resume against the original session id, not the new one.** Read `session_id`
out of `state.json` and pass it explicitly; the pool and the run dirs are both
keyed by the session that created them, and a bare `list` in a fresh session
reports an empty pool while the old lanes are still live:

```bash
bash core/scripts/conduct-pool.sh --session-id "$(jq -r .session_id workspace/orchestrator/{project}/state.json)" list
```

That listing names the live slots and their run dirs. Re-arm a waiter (dispatch
protocol §5) on every slot still `running` **before** doing anything else — an
unwatched live lane is a lane nobody is running — and do not re-dispatch a story
whose lane is still up, however incomplete `state.json` says it is. A story
marked incomplete with a live lane is a story mid-flight, not a story to start
again. `record`, `recycle` and `cancel` all take `--session-id` too; a recovery
that omits it operates on the wrong pool silently.

Progress also lives in `state.json` and `progress.txt`, which the loop updates as it goes; `--status` and `--dry-run` against `{run_project_script}` remain available for out-of-band inspection.

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
- **Do not assume Claude-only primitives** — `Task`, `ExitPlanMode`, `/checkpoint`, and `/compact` are not Codex requirements. The default dispatch is a detached lane, which needs neither.
- **Default is a detached lane per story** — a bare `/run-project {project}` claims a `story:{worker-id}` pool slot and dispatches into it per `.claude/skills/_shared/lane-dispatch-protocol.md`, with nested `/execute-task` worker phases running inside that lane. It auto-continues between stories (no pauses) unless the PRD has >10 incomplete stories or a story requires session mode; dispatch independent stories concurrently up to the pool limit in 3d.
- **In-session `spawn_agent` is the fallback, not the default** — it is correct only on a host where no `codex`/`grok`/`claude` CLI resolves. Probe once per run (dispatch protocol §2) and say which path you took; never fall back silently, and never per story.
- **Ralph/headless is the unattended detached loop** — same lanes, same pool, same return contract as default, run without preflight approval or between-story pauses. It is not `claude -p`: do not pass or accept `--engine`/`--builder`; `run-project.sh` has no `claude` builder and its execution loop is frozen. The engine a lane runs on is the one resolved once for the run (Step 3), from the dispatch protocol's roster.
- **Preserve HQ invariants** — PRD `userStories[].passes`, file locks, active-run coordination, commits per story, and quality gates remain required in every mode.
- **Ask before mode changes** — switching from default inline to parent-driven interactive or Ralph/headless is a user-facing execution semantic. Preserve the decision gate with text fallback if needed.
- **Budget mode is default** — Codex inline must prefer low-reasoning story delegation, compact JSON returns, bounded log reads, changed-repo regression gates, and no parent-side phase fanout.
