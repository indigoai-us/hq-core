---
name: run-project
description: "Execute a project's PRD stories as pooled background worker lanes (never more than CONDUCT_POOL_CAP, default 8) that survive compaction. Interactive mode runs in the parent and takes no pool slots."
allowed-tools: Read, spawn_agent, wait_agent, Bash(bash core/scripts/conduct-pool.sh:*), Bash(bash core/scripts/conduct-inbox.sh:*), Bash(bash core/scripts/hq-session.sh:*), Bash(node core/scripts/workflow-runner.mjs:*), Bash(bash core/scripts/hq-detach.sh:*), Bash(ps:*), Bash(grep:*), Bash(bash:*), Bash(jq:*), Bash(cat:*), Bash(tail:*), Bash(kill:*), Bash(ls:*), Bash(mkdir:*), Bash(echo:*), Bash(sleep:*), Bash(qmd:*), Bash(test:*), Bash(bash core/scripts/work-mesh-live-bind-trusted.sh:*), Bash(sh core/scripts/pipeline-lane-rows.sh:*), Bash(bash core/scripts/pipeline-conductor.sh:*), Bash(bash core/scripts/pipeline-worker-table.sh:*), Bash(sh core/scripts/pipeline-driver.sh:*), Bash, Write, AskUserQuestion, Task, mcp__visualize__read_me, mcp__visualize__show_widget
argument-hint: "{project} [--status] [--resume] [--dry-run] [--inline] [--interactive] [--ralph-mode] [--pipeline] [--in-place] [--timeout N]"
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

**Pipeline mode (`--pipeline`) live children: one loop lane per confirmed
worker-table row, plus the regression-gate lane.** That sum must not exceed
`CONDUCT_POOL_CAP` (default 8); a run that would is refused before any lane
starts (Step 3P). The pipeline driver that routes phases is a detached script,
not a lane, and takes no pool slot.

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
- `--pipeline` — opt-in pipeline mode (Step 3P): one persistent loop-mode lane per worker for the whole run, plus a detached driver script (`core/scripts/pipeline-driver.sh`) that routes story phases through them. Without this flag nothing in Step 3P applies and the default coordinator path (Step 3) runs unchanged.
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
`/conduct` uses: a brief on disk, a detached `workflow-runner.mjs` process, and a
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

**CONFIRM the engine, model and effort with the user before the first dispatch.**
Resolution above picks a *default*; it is not a decision the user has made. A run
is many hours of lane time on whatever model this picks, and the wrong pick is
only visible once the work comes back — so ask once, up front, and never silently
default into a long run. Skip the question ONLY when the user named an engine or
model in the invocation itself.

Ask with a single `AskUserQuestion` (text fallback per
`core/policies/hq-codex-decision-gate-fallback.md`) naming concrete options —
the resolved default first, labelled as such — and covering engine, model, and
reasoning effort together. Then record all three in `state.json` as `engine`,
`engine_model`, and `engine_effort`, and pass them on every lane dispatch.

Passing model and effort to a lane (dispatch protocol §4's `agent()` opts):

| Engine | Model | Effort |
|---|---|---|
| `codex` | `model:` opt, else tier map (`gpt-5.6-sol` plan / `gpt-5.6-terra` exec) | `effort:` opt → `-c model_reasoning_effort=…` |
| `grok` | `model:` opt, else `grok-4.6` | `effort:` opt → `--reasoning-effort` |
| `claude` | `model:` opt, else tier map (`opus` plan / `sonnet` exec) | **not wired** — `workflow-runner.mjs` skips `effort` for claude. Pass it yourself as `extraArgs: ["--effort", "low"]`; the installed CLI accepts `low\|medium\|high\|xhigh\|max` |

Do not assume `effort` reaches a claude lane through the normal opt. It does not,
and a run asked for at low effort will quietly execute at the CLI default.

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

   Before the shared launch block, bind this lane to the story explicitly:

   ```bash
   HQ_SPAWN_TASK="{project}/{story-id}"
   export HQ_SPAWN_TASK
   ```

   This value is owned by the story launcher; never read it from parent-session
   metadata. The shared protocol forwards it to the child runner unchanged.

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

## Step 3P — Pipeline Mode (`--pipeline`)

Only with `--pipeline`. Without the flag, skip this whole step: the default
path is the story coordinator lanes of Step 3, and nothing below changes it.

In pipeline mode each worker gets one persistent `workflow-runner.mjs --loop`
lane for the whole run. A detached driver, `core/scripts/pipeline-driver.sh`,
owns the story queue: it calls `core/scripts/pipeline-conductor.sh` to route
each phase of each story into those lanes through `conduct-pool.sh assign
--envelope`, accepts each phase's handoff, and re-checks acceptance criteria.
The driver makes no engine calls. The parent does not run story coordinators.
Paths below are under `workspace/orchestrator/{project}/pipeline/`; `{state}`
is its `state/` subdirectory.

There is no conductor lane. A lane cannot keep a child process alive past its
own engine call, so a routing loop started inside a lane dies when that call
ends. The `pipeline-conductor` worker (`core/workers/public/dev-team/pipeline-conductor/`)
stays as the written reference for the routing rules the driver follows; it is
not launched, gets no worker-table row, and takes no pool slot.

**3P.1 — Pre-flight first, unchanged.** Run Step 2.5 and the Step 3a preflight
exactly as they run today, including their pauses. If preflight finds stale
state (wrong branch, dirty tree, stale file anchors, missing auth, an unlocked
design), pause and surface it the same way; launch no lane until it is
resolved. Record `session_id` in `state.json` as Step 3 describes. Step 3's
single engine question is replaced by the worker table below. When the
preflight lane returns it is idle: `recycle --worker-id explorer` so it does
not hold a pool slot for the rest of the run.

**3P.2 — Worker sequences, worker table, confirm once.**

A story's worker sequence (`worker_preference`, or the overlay below) is the
full phase sequence for that story, in order: implementer first, then the
reviewers and testers. The lanes are the union of every story's sequence.

First put the preflight's sequences in run state. The Step 3a preflight
explorer emits `ordered_stories[]` with a `worker_sequence` per story; save its
JSON block as `pipeline/preflight-plan.json` and import it into the run's
overlay (`{state}/overlay.json`; prd.json is not edited):

```bash
bash core/scripts/pipeline-conductor.sh classify --prd {prd.json} --state {state} --overlay pipeline/preflight-plan.json
```

An overlay entry wins over `worker_preference`, which wins over the keyword
fallback. Correct one story without a heredoc:

```bash
bash core/scripts/pipeline-conductor.sh overlay set --state {state} --story {id} --sequence backend-dev,qa-tester
bash core/scripts/pipeline-conductor.sh overlay show --state {state}
```

A story the run should not take (out of scope, waiting on someone) goes on the
skip list instead of being deleted from prd.json:

```bash
bash core/scripts/pipeline-conductor.sh skip --state {state} --story {id} --prd {prd.json} --note "{why}"
```

Skipping a story that others depend on prints the dependents it strands and
needs `--force`; `unskip --state {state} --story {id}` reverses it.

Then propose the table from the same sequences:

```bash
bash core/scripts/pipeline-worker-table.sh {prd.json} --overlay {state}/overlay.json
```

It proposes one `row` for every worker any sequence names (architect and
qa-tester included). Show every `row` (worker, engine, model, effort, status,
stories), every `hint` (a story's model_hint) and every `unclassified` story.
A worker with no `worker.yaml` is reported on stderr with the roots searched and
the known ids; fix the sequence rather than answering its row. Then:

- Every row with status `needs-answer` must be answered (engine and model)
  before anything launches. Ask one question per flagged row (AskUserQuestion,
  text fallback per `core/policies/hq-codex-decision-gate-fallback.md`). An
  `unclassified` story needs an overlay entry (`overlay set`) or goes on the
  skip list.
- Do not add a `pipeline-conductor` row: it is not a lane.
- A `model_hint` does not override a confirmed row: the lane's model wins, and
  `--confirmed` prints each hint commented out as "hint ignored, table pins
  <model>". A bare alias (`opus`, `sonnet`, `haiku`) is never passed to an
  engine. To run a story on another model, change that lane's row.
- Then confirm the whole table **once**, before the first dispatch. Until the
  owner confirms and every flagged row is answered, no lane starts and the
  driver does not start.

Write the confirmed table (one `<worker> <engine> <model> [<effort>]` line per
lane) to `pipeline/table.tsv` and check the run against it:

```bash
bash core/scripts/pipeline-conductor.sh classify --prd {prd.json} --state {state} --table pipeline/table.tsv
```

Without `--story` it checks every story that is not passing or skipped and
writes no story state. It must exit 0 before launch. It exits 1 and lists each
problem when a worker id has no `worker.yaml` (naming the nearest known id),
when a story that declares code files has a sequence that starts with a
verifier or reader (it suggests prepending an implementer or marking the story
`"docs_only": true`), or when a sequence worker has no row in the table. Its
`WARN` lines cover one-worker sequences (architect and qa phases will not run),
model hints, and a story whose acceptance criteria or files need a later story
that is not in its `dependsOn` (it prints the `dependsOn` line to use). Relay
the warnings to the owner; they do not block launch.

Turn the table into per-lane exports:

```bash
bash core/scripts/pipeline-worker-table.sh --confirmed pipeline/table.tsv --overlay {state}/overlay.json {prd.json} > pipeline/lanes.env
```

It exits 2 on an empty model or an engine other than `claude`/`codex`/`grok`;
treat that as an unanswered row. Each lane block exports `HQ_CONDUCT_ENGINE`
(the engine its phases run on) and that engine's model and effort pins.

**3P.3 — Cap check: refuse rather than over-subscribe.** Count
`lanes = worker rows + 1 (regression gate)`, where worker rows are the
confirmed rows. The driver is not a lane and is not counted. If `lanes` is
greater than `CONDUCT_POOL_CAP` (default 8), refuse to start and name the cap:

> Refusing --pipeline: {rows} worker lanes + regression gate = {lanes} lanes,
> over CONDUCT_POOL_CAP={cap}. Raise CONDUCT_POOL_CAP or run without
> --pipeline.

Launch nothing in that case. For example, 8 table rows at cap 8 is 9 lanes
and is refused; 7 rows at cap 8 is 8 lanes and runs.

**3P.4 — Approval holds.** Every dev-team implementation worker's worker.yaml
sets `approval_required: true` (`context-manager` and `pipeline-conductor` do
not), so the driver's `route` call holds each phase for those workers
(`route` prints `HELD`, writes `{state}/decisions/<story>-<worker>.md`, exits
10) until the parent releases it. After the table is confirmed, ask once
whether to approve the confirmed workers for the whole run; for each approved
worker run:

```bash
bash core/scripts/pipeline-conductor.sh release --state {state} --worker {worker}
```

A hold that was not pre-approved becomes a decision item (3P.6); release that
story alone with `release --state {state} --story {story-id} --worker {worker}`.
Release marks the decision `approved` and returns the held story to `queued`.

The whole-run worker approval does not release a story that needs an explicit
go. A story needs one when it carries `approval: "explicit"` (the canonical
key; `needsApproval: true` is read as an alias), or when the conductor's
release detector flags it: its declared files or acceptance criteria mention
deploy, release, production, or merging to the base branch (the patterns are
`RELEASE_PATTERNS` in `pipeline-conductor.sh`). Such a story is held
`awaiting_go` before its first implementing phase, whatever the worker's
`approval_required` says (a release story on `qa-tester` is held too), with
`{state}/decisions/<story>-go.md`. `release` does not apply to it. After the
owner says go:

```bash
bash core/scripts/pipeline-conductor.sh go --state {state} --story {story-id}
```

`resolve` and `park` work on an `awaiting_go` story. The driver keeps routing
the rest, lists `awaiting_go` stories on its `TICK` lines in `driver.log` and in
`report.md` `FINAL:`, and exits 21 naming them once nothing else can move.

**3P.5a — Repos, worktrees and branches.** Each story's repo is resolved from
its `repoPath`, then (when the PRD lists more than one repo) from the repo that
owns the story's first declared file, then from `metadata.repoPath`. The repo
list is `metadata.repos[]` (canonical: path strings or objects with `path`);
`metadata.repoPaths[]` is read as an alias. A story whose repo has no worktree
is held `blocked_needs_owner` with a decision item naming the repo; it is never
routed to another repo's tree.

Branch modes:

- Default: one feature branch per repo for the run (`metadata.branchName`, else
  `feature/{project}`). Every story of that repo commits on it in dependency
  order, so a dependent story starts from its dependency's commits. One story
  is in flight per repo branch at a time.
- `--story-branches` (pass it to the driver): one branch and worktree per story
  (`pipeline/{story-id}`), cut when the story first routes, from the branch of
  the last verified story it depends on in the same repo (stacked), else from
  the base. A story whose dependency branch is missing is held, not routed.

Every cut starts from `origin/{baseBranch}` when that ref exists after a fetch,
else from local `{baseBranch}`, never from the repo's HEAD (`metadata.baseBranch`,
default `main`). The exact ref is printed as `CUT <branch> from <ref> <sha>`;
when neither ref exists the cut fails with that message.

Decide before launch (one choice for the run):

| Stories | Worktrees | `PC_MAX_STORIES` |
|---|---|---|
| one repo, or dependent stories in each repo (the usual case) | `worktree --shared` once per repo, default branch mode | the number of repos; the conductor lowers a higher value to that and prints `MAX_STORIES` |
| independent stories that should run side by side in one repo | `--story-branches` | the number of stories to run at once, within `CONDUCT_POOL_CAP` |
| a repo that is not a git repo, or the owner wants one story at a time | serial: bare `--worktree {dir}` | 1 |

Cut one worktree per repo before launch and pass each to the driver:

```bash
bash core/scripts/pipeline-conductor.sh worktree --state {state} --repo {repo} --shared --prd {prd.json}
```

The cut lands at `workspace/worktrees/{project}/{repo-name}/` under the HQ root
(`{repo-name}-{story}` with `--story-branches`), in every mode, never beside
the repo under `repos/`. A worktree must sit inside the HQ root for lanes to cd
into it, and it must not sit under `repos/`: the core Write/Edit guard blocks
editor-tool writes there, so a lane that edits with Write or Edit stalls as
`blocked_needs_owner`. An explicit `--worktree {dir}` or
`--worktree {repo}={dir}` (on `worktree`, `tick`, `classify` or the driver)
that resolves under `repos/` is refused with exit 2 and a message saying why.
Pass `--allow-repos-worktree` only when the owner wants that tree anyway; then
every phase envelope routed into it carries one constraint line telling the
worker to edit through the shell or `apply_patch`.

**3P.5 — Launch: one loop lane per row, then the driver.** For each
confirmed row, in its own shell, export only that row's block from
`pipeline/lanes.env` (each lane has its own engine exports; never share one
export set across lanes), then:

```bash
bash core/scripts/conduct-pool.sh assign --worker-id "{worker}" --task "{project} pipeline lane"
# expect {"action":"spawn"}; exit 3 or 4 -> stop and surface, launch nothing
# launch per .claude/skills/_shared/lane-dispatch-protocol.md §4, with the
# runner in loop mode and no brief:
node core/scripts/workflow-runner.mjs --loop --run-dir "{abs run dir}"
bash core/scripts/conduct-pool.sh record --worker-id "{worker}" \
  --subagent-id "{run id}" --status waiting --pid "{runner pid}" --run-dir "{abs run dir}"
```

Every lane carries `HQ_SESSION_ID` (the session recorded in `state.json`), so
the driver's `conduct-pool.sh` calls and the parent's see one pool. Run-wide
hard limits (no push, no deploy, branch rules) go one per line in
`{state}/constraints.txt`; every phase envelope quotes them.

Once every lane is recorded `waiting`, the parent launches the driver detached,
with `HQ_SESSION_ID` exported, from the HQ root:

```bash
bash core/scripts/hq-detach.sh --logfile {state}/driver/detach.log -- \
  sh core/scripts/pipeline-driver.sh --prd {prd.json} --state {state} \
    --worktree {repo-a}={worktree-a} --worktree {repo-b}={worktree-b} \
    --table pipeline/table.tsv
```

For a single-repo PRD the bare `--worktree {worktree}` form still works.
`--table` makes the driver refuse to route a phase whose worker has no row
(exit 27) instead of leaving the story in flight. Add
`--story-branches` for the stacked mode in 3P.5a. Set `PC_MAX_STORIES` in the
driver's environment as 3P.5a says.

It refuses to start (exit 24) while another driver runs against the same
`{state}`, so launching it twice is safe. The parent then arms one background
waiter on it, with a tool timeout longer than the longest phase deadline:

```bash
until [ -f {state}/driver/exit ]; do sleep 30; done; cat {state}/driver/exit
```

The driver polls every 15 seconds (`--interval`). Each pass it accepts every
handoff a lane wrote to `result_path`, runs `recheck` for finished stories,
and ticks the conductor helper to route the next phase or start the next
story. It appends one line per action to `{state}/driver/driver.log`. When it
exits it writes `{state}/driver/exit` as `<code> <reason>`:

| Code | Meaning | Parent action |
|---|---|---|
| 0 | every story finished (verified, failed after its one reroute, accepted as a partial draft, or parked); `report.md` has its `FINAL:` line | 3P.8 |
| 2 | usage error | fix the command |
| 20 | a regression gate is due | run the gate in the `regression-gate` slot (Step 3c), record `pipeline-conductor.sh gate result pass\|fail --state {state}` (add `--story {id} --note "..."` to a `fail` caused by one verified story: it reopens that story, see 3P.6), relaunch the driver |
| 21 | a decision is needed: a story is held for approval; a phase returned `blocked`, a story has no worktree for its repo, or a story is `awaiting_go`, and nothing else can move; the gate failed; a phase returned `failed` `--max-phase-fails` times; or a phase's engine exited early twice (`engine_exited_early`, see below) (the reason names the status or `engine_exited_early` and the attempt count; the story is then held as `blocked_needs_owner` with `{state}/decisions/<story>-blocked-<phase>.md` carrying each failed handoff's text) | 3P.6: read the decision item, ask the owner once, run the matching command (`resolve --as retry --prd <prd>` re-reads the story's phases, so fix the sequence first with `overlay set` when the lane was wrong; the attempt count starts over), relaunch the driver |
| 22 | an in-flight phase passed its deadline with no handoff | check the lane (`conduct-pool.sh list`, its `stalls.jsonl`), then relaunch the driver or stop the run |
| 23 | the conductor helper printed something unexpected | read the last lines of `driver.log`, surface them, do not relaunch blindly |
| 24 | another driver already runs against `{state}` | leave it; re-arm the waiter on it |
| 25 | retired: the stall check now fires the stall event and exits 28 | - |
| 26 | lane down: routing a phase got a pool answer other than an enqueue into a live loop lane (`spawn` or `resume` means that worker's loop lane is dead). The reason names the lane; the story stays `queued` and the pool claim is released | relaunch that worker's loop lane as 3P.5 launches one and record it `waiting`, then relaunch the driver; it routes the story normally |
| 27 | no lane: a phase's worker has no row in `pipeline/table.tsv`; the reason names the worker and the story stays `queued` | add the row (ask the owner for its engine and model), launch that worker's loop lane as 3P.5 does, relaunch the driver |
| 28 | stall event: for the whole `--stall-window` (default 600 seconds) every started lane is `waiting` with an empty queue while a story is in flight, or an in-flight phase's envelope sits in its lane's queue with nothing active. `{state}/events.jsonl` gets `{"event":"stall","stories":[...],"lanes":[...],"since":<iso>}` and `driver.log` a `STALL` line. The driver has no notification hook, so it writes the event and exits | read the event, check the named lanes (`lane.log`, `conduct-pool.sh list`), relaunch the driver once they are healthy, or stop the run. The same stall does not fire again after a restart; accepting any phase clears it |
| 29 | stopped on request: the parent ran `pipeline-conductor.sh stop` (see "Stopping a run" below) | relaunch the driver when the owner wants to resume |
| 130, 143 | interrupted or terminated; in-flight phases are marked `interrupted` first | relaunch the driver; it routes interrupted stories first |

**Early engine exit.** When a loop lane's engine call for a phase returns
without a usable handoff, the lane writes a failed handoff with
`exit_reason: "engine_exited_early"` and a `phase-exit` event (reason, elapsed
seconds) to its `journal.jsonl`. A handoff whose status is not `passed`,
`failed` or `blocked` is not accepted; with a `phase-exit` event since the
phase was routed it counts the same way. On the next tick the driver logs
`EARLY_EXIT <story>/<phase> after <n>s` and accepts it as a failed phase, which
routes the phase once more to the same lane. A second early exit of that phase
holds the story for the owner (exit 21 naming `engine_exited_early`; the
decision item carries the reason). A phase whose engine is still running keeps
the deadline path (exit 22).

**Pool hygiene at start.** The driver runs `conduct-pool.sh reconcile` once
when it starts, so a finished one-shot lane (a regression gate) never holds its
slot `running`. Lanes count against a machine-wide cap as well as the
session's: `CONDUCT_MACHINE_CAP` (default 16, `0` disables) bounds running and
claimed slots across every session pool on the machine, and `assign` refuses
past it with exit 6 naming the count, the cap and the sessions holding the most.

**Stopping a run.** Stop with
`bash core/scripts/pipeline-conductor.sh stop --state {state} --note "{why}"`.
With a live driver it writes `{state}/driver/stop.json` (a stop envelope,
`{"kind":"stop"}`) and the driver exits 29 on its next pass; with no live
driver it marks the stories itself. Every stop path (that command, SIGTERM,
SIGINT, and a loop lane that exited on a stop envelope while a story was in
flight on it) marks each `in_flight` story `interrupted` with the phase and
time in `stories/<id>.json`, withdraws its envelope from the lane queue when no
lane picked it up, and keeps a partial handoff as
`handoffs/<id>-<phase>.interrupted.<n>.json`. A phase whose handoff already
finished it is left for the next driver to accept. The relaunched driver routes
interrupted stories first, before reopened ones, at the interrupted phase; the
envelope carries `resumed_after_interrupt: true` and `prior_handoff` when a
partial handoff exists. `TICK` lines in `driver.log` and the `FINAL:` line name
interrupted stories until they are routed again.

A handoff with status `failed` is routed again until it has failed
`--max-phase-fails` times (default 2). A handoff with status `blocked` is never
routed again: a rerun cannot help. The conductor holds that story as
`blocked_needs_owner`, writes `{state}/decisions/<story>-blocked-<phase>.md`
with the story, phase, lane and the worker's own blocker text, and the driver
keeps routing every story that does not depend on it. A blocked story does not
take a slot under `PC_MAX_STORIES`.

Every relaunch uses the same command. The driver reads all of its state from
`{state}`, so a relaunch resumes where the last one stopped and does not run a
finished phase again.

No step here starts a background shell loop inside a lane. The driver is the
only loop, and it runs outside every lane.

**3P.6 — Relay, do not drive.** While the run is live the parent:

- Ends every turn in which a pipeline lane is live with the lane rows. Pull
  them once with
  `sh core/scripts/pipeline-lane-rows.sh --state {state} --session-id {session_id}`
  (one JSON array: an item per loop lane in the session pool and one
  `kind: "driver"` item). Call `mcp__visualize__read_me` with `["mockup"]`
  once per session first, silently, then render `mcp__visualize__show_widget`
  in HTML mode from the template `.claude/skills/conduct/lane-rows.html`: one
  `.row` per worker lane plus one for the driver, the CSS untouched, flex rows,
  never a grid or cards. Per lane row: the worker; the phase chip from
  `phase_label`; the meta from `phase_elapsed_s`, `quiet_s` and
  `inbox_pending`; a rough percentage from `phase_index` of `phase_count`
  (`(phase_index - 1) / phase_count`, never 100% before the story is
  verified); the story title in plain words; `last_line` in plain words; the PR
  link when `pr` is set. Dot: green when the lane runs and is active; yellow
  when it waits on an envelope, on the owner, or has been quiet 20 minutes or
  more (`quiet_s` >= 1200); red when `pid_alive` is false on a lane that has
  not exited, or the driver exited non-zero; blue on a lane that exited 0
  (`exit` is `0`). The driver row carries the story counts (verified,
  in_flight, queued, blocked, parked, skipped, interrupted, awaiting_go) and
  its `last_line`. Then the one-line reply. Nothing the owner must decide goes
  in a row: that is `/decision-queue`, after the rows. Zero live lanes means no
  rows.
- Relays the per-story report lines from `{state}/report.md` (one line per
  finished story, one `FINAL:` line at the end). It does not report per
  phase.
- Surfaces decision items through the decision queue (`/decision-queue`), one
  at a time: approval items in `{state}/decisions/` marked `status: pending`,
  and lane items (stalled phases) in `workspace/sessions/<id>/decisions.jsonl`,
  which `bash core/scripts/conduct-pool.sh decisions` prints (see the stalled
  loop lanes part of `.claude/skills/_shared/pool-lane-protocol.md` §2). Apply
  each answer with `pipeline-conductor.sh release`, or as the item's options
  describe, then relaunch the driver.
- On exit 21 for a blocked story (`decisions/<story>-blocked-<phase>.md`,
  `status: pending`): read the decision item, ask the owner once and quote the
  worker's blocker text from it, run the one command that matches the answer,
  then relaunch the driver with the same command as before. None of these is
  ever applied without the owner's answer.

  | Owner's answer | Command |
  |---|---|
  | accept it as a partial draft; let dependents start | `bash core/scripts/pipeline-conductor.sh resolve --state {state} --story {id} --as accepted-partial --note "{owner's reason}"` |
  | run the phase again with this answer | `bash core/scripts/pipeline-conductor.sh resolve --state {state} --story {id} --as retry --note "{owner's answer}"` |
  | set it aside with everything that depends on it | `bash core/scripts/pipeline-conductor.sh park --state {state} --story {id} --note "{why}"` |
  | bring a parked story back | `bash core/scripts/pipeline-conductor.sh unpark --state {state} --story {id}` |
  | leave a story out of the run | `bash core/scripts/pipeline-conductor.sh skip --state {state} --story {id} --prd {prd.json} --note "{why}"` (add `--force` only after the owner accepts the stranded dependents it lists) |
  | go for a story held `awaiting_go` | `bash core/scripts/pipeline-conductor.sh go --state {state} --story {id}` |

  `accepted-partial` is a terminal state, separate from `verified`: it counts
  as done for `dependsOn`, its report line and the `FINAL:` line list the
  owner's note and the unmet acceptance criteria, and `passes` stays unset.
  Do not write `passes: true` for it. `retry` routes the phase as a fresh call
  with the owner's note in the envelope. `park` holds every story that depends
  on the parked one, directly or not, as `parked_dependency`; the `FINAL:` line
  lists parked stories and why. `park` prints `PARK_CLOSURE <id> <n>: <ids>`
  before it acts; when it would park more than `PC_PARK_CONFIRM` (default 5)
  stories it refuses until it is repeated with `--force`. Show the owner that
  list and ask before adding `--force`. `unpark` prints what it releases. Park,
  unpark, skip and unskip each add a line to `{state}/decisions.log`. Each command refuses a story in a state it
  does not apply to (exit 1) and prints `ALREADY` when repeated.
- On exit 20, if the gate fails because of one story the run already
  verified (its own QA passed because the guard test lives outside its suite),
  record the failure naming that story instead of a plain `fail`:
  `bash core/scripts/pipeline-conductor.sh gate result fail --state {state} --story {id} --note "{what the gate found}"`.
  The conductor reopens the story and sets the gate to `reopened`, which does
  not stop routing; the relaunched driver routes that story first. The same
  works after a plain `gate result fail` was already recorded. To send a
  story back without a gate, run
  `bash core/scripts/pipeline-conductor.sh reopen --state {state} --story {id} --note "{why}" [--from-phase {phase}]`.
  Reopen applies to a `verified` or `accepted_partial` story. It queues the
  story at `--from-phase` (default: the first phase whose worker is not a
  reviewer or tester), archives that phase's and later handoffs as
  `handoffs/<id>-<phase>.reopened.<n>.json`, starts the attempt count over,
  puts the note in the next envelope (`reopen_note` and a constraint line),
  and sets `passes` back to false in prd.json if it was true, saying so.
  Stories that depend on it and are already verified are not reopened; the
  `FINAL:` line lists them as "verified before {id} was reopened" for the
  owner to decide. Once every reopened story verifies again the gate is due
  (exit 20): run it and record `pass` or `fail` as usual. Reopen refuses
  other states (exit 1) and prints `ALREADY` when repeated.
- Records `passes: true` in prd.json for a story only after the report says it
  is verified; the driver and the conductor helper never write `passes`.

**3P.7 — After a parent compaction, recover from disk.** The run state lives
in files, not in the parent's context. After a compaction or in a new session,
rebuild it from `state.json` (`session_id`), `pipeline/table.tsv`,
`{state}/stories/` (each story's phase and state), `{state}/report.md`,
`{state}/decisions/`, `{state}/driver/` (`driver.pid` while it runs, `exit`
once it stopped, `driver.log`), `workspace/sessions/<id>/decisions.jsonl`, and
`conduct-pool.sh --session-id {session_id} list` for the live lanes. Do not
relaunch a lane the pool lists as `waiting` or `running`. If `driver.pid`
names a live process, re-arm the waiter; if `exit` is present, act on its code;
if neither, relaunch the driver.

**3P.8 — Run end: stop every lane.** When the driver exits 0 and `report.md`
has its `FINAL:` line, send every worker lane a stop envelope
(`{"kind":"stop"}`; the loop exits 0 once the phases queued ahead of it are
done):

```bash
printf '{"kind":"stop"}\n' > pipeline/stop.json
bash core/scripts/conduct-pool.sh assign --worker-id "{worker}" --envelope pipeline/stop.json
```

Once each lane has exited, `recycle --worker-id "{worker}"` its slot. The run
is finished only when `conduct-pool.sh list` shows no `waiting` or `running`
slot for it. Then continue with Step 6.

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
- **Carry the parent company into every detached lane** — before the shared launch block, resolve `HQ_SPAWN_COMPANY` with `hq-session.sh --session-id "$SID" get company_slug` and stop if it is empty; set optional `HQ_SPAWN_PROJECT` from the owning session metadata. For a story lane, set and export `HQ_SPAWN_TASK="{project}/{story-id}"` explicitly. The shared block exports those values with `HQ_PARENT_SESSION_ID`, so SessionStart binds the engine's child session rather than treating the parent `HQ_SESSION_ID` as the child. Never infer a company from cwd, and never recover a task from parent-session metadata: a lane without an explicitly owned task receives none.
- **In-session `spawn_agent` is the fallback, not the default** — it is correct only on a host where no `codex`/`grok`/`claude` CLI resolves. Probe once per run (dispatch protocol §2) and say which path you took; never fall back silently, and never per story.
- **Ralph/headless is the unattended detached loop** — same lanes, same pool, same return contract as default, run without preflight approval or between-story pauses. It is not `claude -p`: do not pass or accept `--engine`/`--builder`; `run-project.sh` has no `claude` builder and its execution loop is frozen. The engine a lane runs on is the one resolved once for the run (Step 3), from the dispatch protocol's roster.
- **Preserve HQ invariants** — PRD `userStories[].passes`, file locks, active-run coordination, commits per story, and quality gates remain required in every mode.
- **Ask before mode changes** — switching from default inline to parent-driven interactive or Ralph/headless is a user-facing execution semantic. Preserve the decision gate with text fallback if needed.
- **Budget mode is default** — Codex inline must prefer low-reasoning story delegation, compact JSON returns, bounded log reads, changed-repo regression gates, and no parent-side phase fanout.
