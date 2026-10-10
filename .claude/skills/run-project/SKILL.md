---
name: run-project
description: "Execute a project's PRD stories through HQ worker lanes that survive compaction. Interactive mode runs in the parent."
allowed-tools: Read, spawn_agent, wait_agent, Bash(hq lanes create:*), Bash(hq lanes list:*), Bash(hq lanes wait:*), Bash(hq lanes message:*), Bash(hq lanes questions:*), Bash(hq lanes story:*), Bash(bash core/scripts/hq-session.sh:*), Bash(node core/scripts/workflow-runner.mjs:*), Bash(bash core/scripts/hq-detach.sh:*), Bash(ps:*), Bash(grep:*), Bash(bash:*), Bash(jq:*), Bash(cat:*), Bash(tail:*), Bash(kill:*), Bash(ls:*), Bash(mkdir:*), Bash(echo:*), Bash(sleep:*), Bash(qmd:*), Bash(test:*), Bash(bash core/scripts/work-mesh-live-bind-trusted.sh:*), Bash(sh core/scripts/pipeline-lane-rows.sh:*), Bash(bash core/scripts/pipeline-conductor.sh:*), Bash(bash core/scripts/pipeline-worker-table.sh:*), Bash(sh core/scripts/pipeline-driver.sh:*), Bash, Write, AskUserQuestion, Task, mcp__visualize__read_me, mcp__visualize__show_widget
argument-hint: "{project} [--status] [--resume] [--dry-run] [--inline] [--interactive] [--ralph-mode] [--pipeline] [--in-place] [--timeout N]"
---

# Run Project — Codex Router

Codex does not use Claude Code's `Task`, `Plan` sub-agents, `ExitPlanMode`, `/checkpoint`, or `/compact` primitives. The default story path creates an HQ worker lane for each story. If lane execution is unavailable, Codex can use the documented in-session `spawn_agent` / `wait_agent` fallback.

**Default story execution:** one HQ worker lane for each active story, created
with `hq lanes create` and this session as senior. Interactive mode stays in the
parent; the pipeline lane behavior below remains separate.

**Pipeline mode (`--pipeline`) live children: one loop lane per confirmed
worker-table row, plus the regression-gate lane.** `hq lanes create` enforces
company admission and capacity. A capacity refusal leaves the story queued for
the next driver tick. The pipeline driver that routes phases is a detached
script, not a lane, and takes no lane slot.

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
- `--inline` — the default: dispatch each story through `/execute-task` in an HQ worker lane (Step 3). The name is historical; it means story-delegated execution, as opposed to `--interactive` parent-driven editing.
- `--interactive` or `--session-mode` — parent-driven Codex execution
- `--ralph-mode` — the same HQ lane story loop as default, run unattended: skip the preflight approval, auto-advance through every story without between-story pauses, and report once at the end
- `--pipeline` — opt-in pipeline mode (Step 3P): one persistent loop-mode lane per worker for the whole run, plus a detached driver script (`core/scripts/pipeline-driver.sh`) that routes story phases through them. Without this flag nothing in Step 3P applies and the default coordinator path (Step 3) runs unchanged.
- `--in-place` — (ralph) skip feature-branch pre-creation; work on the current checkout
- `--timeout N` — (ralph) per-story wall-clock budget in minutes before a story is marked `blocked: TIMEOUT`. This is the waiter's `deadline` file (dispatch protocol §4-§5), not the runner's `timeoutSecs` — that one only warns and never kills, so it cannot bound anything on its own.
- `--resume` continues from the next incomplete story (read from `state.json`)

If no execution mode is supplied, route to `--inline`. Each story runs through `/execute-task` in its own HQ worker lane, so the parent holds coordination state only.

Use `--interactive` only when the user asks to steer edits directly in the parent session; it is the one mode that does not dispatch lanes at all. Use `--ralph-mode` for long unattended runs where you do not want to be prompted between stories — it executes the identical worker-authoritative lane loop, just without the pauses.

**Recommendation posture:** always recommend `--inline`. It runs **continuously — no pause between stories** — except when either condition holds:

1. The PRD has **more than 10 incomplete stories** → pause at the preflight plan for one approval, then run continuously.
2. A story **requires session mode** (its notes or classification demand parent-driven interactive steering) → pause before that story only, run it interactively, then resume continuous flow.

Everything else auto-continues exactly like ralph-mode. Failed or blocked stories still stop the queue.

> **Note on the legacy detached orchestrator — not the same thing as a lane.** Earlier versions of this skill launched a detached shell subprocess (`nohup bash run-project.sh … --engine claude`) that ran one headless `claude -p` builder per story, outside the pool and outside the worker system. *That* path is retired: `run-project.sh`'s execution loop is frozen and kept only for `--status`, `--dry-run`, and `--help`; it no longer runs stories, and it has no `claude` builder. The `--engine`/`--builder`, `--swarm`, `--tmux`, `--codex-autofix`, and `--no-monitor` flags belonged to it and are not accepted.
>
> Current story lanes are created through `hq lanes create`, carry the invoking session as senior, and run `/execute-task` rather than a bare headless builder.

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

## Step 3 — Default Execution: Story Lanes

The parent plans and coordinates. Each story runs through `/execute-task` in a
worker lane created with `hq lanes create`; the lane is attributed to the bound
company, project, and story, and this invoking session is its senior. The lane
runs the existing worker phases, quality gates, handoffs, and commit checks in
`.claude/skills/execute-task/SKILL.md`.

Resolve the engine and model choices once for the run using the current
interactive decision gate. Record the selected values with the run state and
reuse them for each story. Pass `--provider`, `--model`, and `--effort` to lane
creation only when a worker profile or an explicit `/conduct --workers` pin
supplies that value. If no provider CLI is available, retain the existing
in-session `spawn_agent`/`wait_agent` fallback and say which path is in use.

### 3a. Preflight Plan

Keep the existing preflight: resolve the PRD and company, validate the target
repo and story dependencies, classify incomplete stories with `/execute-task`
rules, read applicable hard policies, and present the ordered plan. For ten or
fewer incomplete stories with no session-mode requirement, proceed without an
extra approval pause. Otherwise ask the user to approve or adjust the plan,
switch to `--interactive` or `--ralph-mode`, or stop. The parent may use a read-only explorer to produce the plan; it does not own a story or change board status.

Before dispatch, record the run's company, project, session id, provider choice,
model, and effort in `workspace/orchestrator/{project}/state.json`. On resume,
keep the original session id and lane ownership. Never infer company from cwd.

### 3b. Story Loop

For each approved incomplete story:

1. Announce the story id, title, and worker sequence. Keep the existing branch
   setup, state tracking, and best-effort Linear sync.
2. Write the story brief to a file and create the story worker lane:

   ```bash
   hq lanes create --company "{company}" --project "{project}" \
     --story "{story-id}" --worker "{worker-id}" \
     --brief-file "{brief path}" --senior "session:{session-id}" --json
   ```

   The brief tells the lane to run `/execute-task {project}/{story-id}` and
   includes `RETURN CONTRACT: json`, applicable policies, the target repo, and
   the `verify-story-deliverables.sh` evidence gate. Use
   the same story id for every lane created for its phases. A repeat create for
   the same worker under the same senior continues that worker's previous
   thread. If its lane is live, send the follow-up with `hq lanes message`.
   Read the JSON body for `ok`, `lane_id`, and admission/capacity errors. A
   capacity refusal leaves the story queued for the next tick.
3. Start and verify the policy-required detached watcher, then wait with `hq lanes wait --any {lane-id} --for envelope
   --for question --for state --timeout {seconds} --json`. Questions use the
   existing user decision flow and `hq lanes questions` commands.
4. Read the latest lane envelope from `hq lanes list --json` and its
   `last_envelope.ref`. Parse the envelope with `jq -e`, then validate the story id, worker proof, artifacts,
   back-pressure results, and parent-visible commits before advancing. Retry
   malformed JSON exactly once with the existing stricter reminder; if the
   second result is malformed, mark the story blocked with
   `INVALID_RETURN_FORMAT` and stop the queue.
5. Preserve the one-line story narration and bounded parent reads. Keep detailed
   logs and long notes on disk. Do not use conduct pool state as the result
   source.
6. Update story status through the board and `hq lanes story` wherever the
   skill already updates status. Do not add status fields to local `prd.json`;
   `passes` remains spec acceptance data, not a board column. Mark `passes: true`
   only after the existing evidence and quality gates pass.

Stories are dispatched one at a time by default. Independent stories may run
concurrently only when their worker ids differ, they have no dependency or file
conflict, and lane admission accepts each create. A same-worker story reuses its
existing lane. Do not create a second lane for a worker that is still live; use
`hq lanes message` for its next brief. Admission and capacity refusals remain
queued for a later tick rather than bypassing the lane limit.

### 3c. Regression Gates

Keep the existing budget-aware regression cadence: every three completed
stories, run the applicable `metadata.qualityGates` for repos touched since the
last gate. Run the full matrix at final completion, before deploy, after a
high-risk cross-repo contract change, or when explicitly requested. A gate may
run in a worker lane with the same `--company`, `--project`, `--story`,
`--brief-file`, and session senior mapping; read its result from its lane
envelope. Keep detailed logs on disk and the parent transcript to compact JSON.
A failed gate stops story advancement and follows the existing user decision
path.

### 3d. Budget and Recovery

- Worker lanes are created with `hq lanes create`; admission and capacity are
  owned by HQ lanes. Keep only one lane per worker and senior, and use
  `hq lanes message` while it is live.
- A completed phase's result comes from its lane envelope. `hq lanes list
  --json` provides lane state and the latest envelope reference; it is not a
  substitute for reading the envelope itself.
- A lane that is still live after the parent turn is resumable. On recovery,
  list only lanes owned by the original `session:{session-id}` and this project,
  re-arm watchers for live lanes, and do not dispatch the same story again
  while its lane is running.
- Keep one story active by default. Independent stories can overlap only under
  the constraints in 3b and only when create succeeds.
- Do not simulate `/execute-task` by spawning worker-phase agents from the
  parent. If the story lane cannot run `/execute-task`, use the existing
  in-session fallback or pause with the current blocker.
- Read bounded output only. Use compact envelopes and short tails, not raw test
  logs or full output files.

## Step 3P — Pipeline Mode (`--pipeline`)

Only with `--pipeline`. Without the flag, skip this whole step: the default
path is the story coordinator lanes of Step 3, and nothing below changes it.

In pipeline mode each worker gets one `hq lanes` loop lane for the whole run.
A detached driver, `core/scripts/pipeline-driver.sh`, owns the story queue: it
calls `core/scripts/pipeline-conductor.sh` to route each phase with
`hq lanes enqueue`, accepts each phase's handoff, and re-checks acceptance criteria.
The driver makes no engine calls. The parent does not run story coordinators.
Paths below are under `workspace/orchestrator/{project}/pipeline/`; `{state}`
is its `state/` subdirectory.

There is no conductor lane. A lane cannot keep a child process alive past its
own engine call, so a routing loop started inside a lane dies when that call
ends. The `pipeline-conductor` worker (`core/workers/public/dev-team/pipeline-conductor/`)
stays as the written reference for the routing rules the driver follows; it is
not launched, gets no worker-table row, and takes no lane slot.

**3P.1 — Pre-flight first, unchanged.** Run Step 2.5 and the Step 3a preflight
exactly as they run today, including their pauses. If preflight finds stale
state (wrong branch, dirty tree, stale file anchors, missing auth, an unlocked
design), pause and surface it the same way; launch no lane until it is
resolved. Record `session_id` in `state.json` as Step 3 describes. Step 3's
single engine question is replaced by the worker table below. The preflight
lane is separate from the loop lanes created for the pipeline phases.

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

**3P.3 — Lane admission.** The conductor creates one `hq lanes` loop lane the
first time a worker is routed, then reuses that lane for the worker's later
phases. The CLI applies lane capacity and company admission. If `create` returns
`ok:false` with an admission or capacity error code, the story stays queued and
the driver retries on its next tick. The driver itself is not a lane.

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
| independent stories that should run side by side in one repo | `--story-branches` | the number of stories to run at once, bounded by the worktrees and lane admission |
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

**3P.5 — Launch the driver.** The driver creates a company-bound loop lane
the first time each worker is routed and records `{worker_id: lane_id}` in
`{state}/lanes.json`. It reads engine, model, and effort from the confirmed
worker table. The session must have a company bound before the first route.
Run-wide hard limits (no push, no deploy, branch rules) go one per line in
`{state}/constraints.txt`; every phase envelope quotes them. Launch the driver
detached from the HQ root with `HQ_SESSION_ID` exported:

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
| 22 | an in-flight phase passed its deadline with no handoff | check the lane with `hq lanes list --json`, then relaunch the driver or stop the run |
| 23 | the conductor helper printed something unexpected | read the last lines of `driver.log`, surface them, do not relaunch blindly |
| 24 | another driver already runs against `{state}` | leave it; re-arm the waiter on it |
| 25 | retired: the stall check now fires the stall event and exits 28 | - |
| 26 | lane down: `hq lanes enqueue` reports `loop_not_running`; the story stays `queued` and its worker mapping is removed | restart the driver; the next route creates a fresh loop lane |
| 27 | no lane: a phase's worker has no row in `pipeline/table.tsv`; the reason names the worker and the story stays `queued` | add the row (ask the owner for its engine and model), launch that worker's loop lane as 3P.5 does, relaunch the driver |
| 28 | a loop lane parked its phase after repeated stalls and raised a question | list its pending question with `hq lanes questions list --company {company} --json`, answer it, then restart the driver |
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

**Loop lane admission.** `hq lanes create --loop` applies lane admission and
capacity rules. Admission or capacity refusals leave the story queued for the
next tick. A stopped or failed lane is removed from `lanes.json` and recreated
on the next route.

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
  (one JSON array: an item per mapped hq loop lane and one
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
  and loop lane questions with `hq lanes questions list --company {company}
  --json`. Answer with `hq lanes questions answer`. Apply
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
`hq lanes list --json` filtered to ids in `{state}/lanes.json` for live lanes.
Do not relaunch a lane whose loop state is `waiting` or `running`. If `driver.pid`
names a live process, re-arm the waiter; if `exit` is present, act on its code;
if neither, relaunch the driver.

**3P.8 — Run end: stop every lane.** The driver stops each lane id in
`{state}/lanes.json`. It reports completion only when `hq lanes list --json`
shows every owned loop state as `stopped` or the lane is absent from the list.
It clears the mapping after confirmation so a resumed run creates fresh lanes.
Then continue with Step 6.

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
session: `hq lanes list --json` shows the lanes launched by the session, and
`state.json` says which stories are done. A genuinely self-driving run would
need the loop itself dispatched as a lane — an extra coordinator level with its
own lane accounting — which does not exist today. Do not tell a user their run
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
hq lanes list --json --senior "session:$(jq -r .session_id workspace/orchestrator/{project}/state.json)"
```

That listing names the live lanes and their current state. Re-arm a waiter (dispatch
protocol §5) on every lane still `running` **before** doing anything else — an
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

- **Do not reference `.Codex/commands/run-project.md` as required source** — this skill is the Codex router.
- **Do not assume Claude-only primitives** — `Task`, `ExitPlanMode`, `/checkpoint`, and `/compact` are not Codex requirements.
- **Default stories run through `/execute-task` in an HQ worker lane** created with `hq lanes create`, using the bound company, project, story, worker, brief file, and `--senior session:{id}`. Interactive mode stays parent-driven.
- **Carry trusted company and story context into every lane** — resolve the company from the run state and pass the project and story explicitly. Never infer a company from cwd.
- **Use lane results as the delivery record** — inspect `hq lanes list --json`, then read the latest envelope. Do not infer success from local process state or exit code.
- **Preserve HQ invariants** — PRD acceptance data, board status, file locks, active-run coordination, commits per story, JSON returns, evidence, and quality gates remain required in every mode.
- **Ask before mode changes** — switching from the default story-lane path to parent-driven interactive or Ralph/headless is a user-facing execution semantic. Preserve the decision gate with text fallback if needed.
- **Budget mode is default** — prefer low-reasoning story execution, compact JSON returns, bounded log reads, changed-repo regression gates, and no parent-side phase fanout.
