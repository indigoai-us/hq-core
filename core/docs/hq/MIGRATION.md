# HQ Migration Guide

Newest release first. `## Release: TBD` collects promotions staged for the next
release; the release workflow stamps it with the version at tag time.

## Release: v15.0.128-beta.3

- promote 2026-09-11 (conduct pool): **`record` no longer accepts `--status recycled`.** That path
  marked a running slot recycled and cleared its sub-agent id directly, routing around both the
  running-lane guard and the handoff purge — a caller could retire a live lane and be granted its
  replacement while the original kept working. Retirement is `recycle` (with `--force` only after a
  confirmed stop) or `cancel`.
- promote 2026-09-11 (orchestrator skills use the pool): the dispatch sequence is now executable on
  both runtimes, and says which is which. Codex gets an id between `spawn_agent` and `wait_agent`, so
  `record --status running` goes there. Claude Code's `Task` dispatches and blocks in one call, so
  record first with `--subagent-id pending` and replace it on return. Recording *after* the wait
  would leave live work marked `claimed` for its whole duration — exactly the state `cancel` is
  allowed to retire.

- promote 2026-09-11 (conduct pool): **a slot now has four states, not three.** `assign` grants a
  lane as `claimed`; `record --status running` is what attaches a sub-agent and makes it `running`.
  `cancel` keys on `claimed`, and on nothing else. The emptiness of `subagent_id` would not have
  worked as the test: a
  *resume* claim keeps the previous lane's id while it waits to be dispatched, so keying on
  emptiness refused exactly the cross-tenant reset `cancel` exists for. `claimed` counts against the
  cap and makes a second `assign` for that worker exit 4, so the slot is held from the moment it is
  granted. `recycle` still works on a `claimed` lane — there is no sub-agent to strand — so the
  guard does not block its own remedy.
- promote 2026-09-11 (conduct pool): `assign`'s own exit-3 and exit-4 diagnostics no longer
  recommend an unforced `recycle`, which the running-lane guard makes fail deterministically. They
  now say to wait, and name `--force` (after a confirmed stop) or `cancel` (for an undispatched
  claim) as the applicable escapes.
- promote 2026-09-11 (conduct pool): **`/conduct` lanes are namespaced `conduct:{worker-id}`.** A
  `/conduct` lane stores a workflow-runner run directory as its `subagent_id` while an
  `/execute-task` phase lane stores a `Task` / `spawn_agent` handle, and only the latter carries an
  `owner.json` stamp. Sharing the bare worker id meant a session that used both would hand one
  runtime's handle to the other's adapter, and let `/conduct` resume a phase lane with no ownership
  check. Three namespaces now: bare id for phases, `story:` for coordinators, `conduct:` for
  `/conduct`.

- promote 2026-09-11 (conduct pool): new verb `conduct-pool.sh cancel --worker-id <id>` — retire a
  claim that was never dispatched. `assign` grants every slot as `claimed`, so a caller that backs
  out (most often because the slot's ownership stamp names another tenant) hit the running-lane
  refusal and the ownership reset had no way to complete. `cancel` keys solely on `status ==
  claimed`, and refuses with exit 5 for anything else. It does **not** test whether `subagent_id` is
  empty: a resume claim keeps the previous lane's id, so emptiness would refuse exactly the reset
  this verb exists for. Status is a fact the helper records at grant time rather than an assertion
  it accepts, which is why `cancel` needs no `--force` and cannot abandon a live lane. It clears the
  slot's `handoffs.jsonl` and `owner.json` like `recycle` does.
- promote 2026-09-11 (conduct pool): `/conduct` step 3's exit-3 guidance no longer advertises an
  unforced `recycle`, which the new guard makes exit 5 deterministically. It offers waiting, or
  `--force` once the user has stopped the lane, or `cancel` for a claim it never launched.

- promote 2026-09-11 (conduct pool): **`conduct-pool.sh recycle` now refuses a running lane with
  exit 5.** Retiring a slot frees the pool entry and leaves the sub-agent alone — the pool records
  ids, it does not own processes — so retiring a live lane put the real child count over the cap and
  let the next claimant share a run directory with a process still writing to it. Wait for the lane
  and mark it `idle`, or stop it and pass `--force` to assert you did. The exit-3 guidance no longer
  points at `recycle` as an escape hatch.
- promote 2026-09-11 (conduct pool): recycling now **clears the lane's `handoffs.jsonl` and
  `owner.json`**, on both the explicit path and the LRU retirement inside `assign`. Recycling is how
  a fat lane is discarded; leaving the file behind meant the next claim of the same worker — same
  company, same project, so the ownership stamp matched — read back the whole transcript the recycle
  was meant to drop, growing without bound across recycles. A recycled lane always restarts cold.
- promote 2026-09-11 (orchestrator skills use the pool): the coordinator budget is
  `max(1, (CONDUCT_POOL_CAP - 2) / 2)`. The bare formula yields 0 at a cap of 2 or 3 — both accepted
  by the helper — which would permit no coordinator and stall `/run-project` before its first story.
  At those caps the reserved explorer/gate pair is what does not fit: recycle those slots once used
  and run one coordinator serially. A cap of 1 cannot host a coordinator and its phase at all, so the
  skill stops and offers a higher cap or `--interactive` rather than improvising.

- promote 2026-09-11 (orchestrator skills use the pool): the lane protocol is now stated **once**, in
  `.claude/skills/_shared/pool-lane-protocol.md`, and `/execute-task` and `/run-project` follow it
  rather than restating it. Every time the two descriptions drifted during review, one of them was
  wrong — a coordinator id the pool rejects outright, an ownership check that existed on only one
  dispatch path, a resume branch with no executable body. The protocol covers namespaces and the id
  charset, the `assign` exit codes, `mkdir -p` before any slot-directory access (`assign` writes a
  pool entry in `meta.yaml` and nothing on disk, so the first use has no directory), the ownership
  stamp, the disk-backed restart for runtimes with no resume primitive, release, and the nesting
  budget.
- promote 2026-09-11 (orchestrator skills use the pool): `/run-project`'s own lanes are
  ownership-checked too. `explorer` and `regression-gate` are constant ids shared across every
  project and company, which makes them the lanes most likely to hand one tenant's context to
  another — a second `/run-project` in one session would otherwise resume the first one's planning
  transcript, or a gate lane carrying another company's repo list.
- promote 2026-09-11 (orchestrator skills use the pool): the coordinator `resume` branch has a
  concrete body. Codex `spawn_agent` always starts a new agent, and `assign` has already marked the
  slot `running` by the time `resume` comes back, so a coordinator that could not act on it left the
  lane stuck and every later claim for that worker at exit 4.

- promote 2026-09-11 (orchestrator skills use the pool): story coordinator lanes are namespaced
  `story:{worker-id}` (a colon, because the pool rejects ids outside `[A-Za-z0-9._:-]`); the phases inside them claim the bare worker id. A coordinator holding
  `backend-dev` would send its own `api_development` phase to `assign` exit 4 — waiting on a lane the
  coordinator itself holds, with the coordinator waiting on that phase. Neither ever finishes.
  Concurrent stories are capped at `(CONDUCT_POOL_CAP - 2) / 2` (**3** at the default cap of 8) so
  every live coordinator can still claim the one phase lane it needs; fill the pool with coordinators
  and every one blocks on exit 3 with nothing running that could release a slot.
- promote 2026-09-11 (orchestrator skills use the pool): lane continuity moved from
  `workspace/orchestrator/{project}/pool/…` to `workspace/sessions/{session-id}/pool/…`, beside the
  pool state that owns the slot. A project slug is not unique across companies, and a project-keyed
  file outlives the session that wrote it — either way a lane reads another tenant's or another day's
  history as its own and skips live work. The directory carries an `owner.json` stamp (company,
  project, session); a missing or mismatched stamp means `cancel` the claim, delete its
  `handoffs.jsonl`, re-stamp, and dispatch cold. The check runs before the spawn/resume split, so a
  runtime with a native resume primitive cannot skip it, and the reinitialise matters because 6d's
  append is unconditional — leaving the file would file this owner's phases under the previous
  owner's stamp.

- promote 2026-09-11 (orchestrator skills use the pool): `/execute-task` step 6c no longer spawns a
  sub-agent per phase. It claims the worker's lane with `conduct-pool.sh assign --worker-id <id>`
  first, resumes on `action=resume`, and records the lane `running` around the blocking call and
  `idle` once the phase JSON validates. `assign` exit 3 (pool at cap, all running) and exit 4 (this
  worker's lane is already running) both mean wait — neither changes the pool, so dispatching past
  them is how a run exceeds the cap or relaunches into a directory a live process still owns.
- promote 2026-09-11 (orchestrator skills use the pool): neither Claude Code's `Task` nor Codex
  `spawn_agent` can re-enter an existing sub-agent, so 6c documents the honest fallback instead of a
  fake resume — dispatch afresh, point the worker at
  `workspace/sessions/{session-id}/pool/{worker.id}/handoffs.jsonl`, and record the new sub-agent id
  against the **same** slot. The cap counts lanes, not restarts. The inline codex-reviewer path is
  unchanged and takes no slot, because it runs in the parent.
- promote 2026-09-11 (orchestrator skills use the pool): `/run-project` fan-out is now bounded by the
  pool rather than by the story count. The preflight explorer, each story's classified worker, and
  the regression gate are named slots that resume. **Typical run: 3-4 live lanes. Worst case:
  `CONDUCT_POOL_CAP`, default 8** — a 40-story PRD opens no more lanes than a 4-story one. Stories
  that classify to the same worker id serialize on that one lane. Parallel swarming survives but is
  capped at the pool's remaining capacity instead of dispatching one worker per story.
- promote 2026-09-11 (orchestrator skills use the pool): `--interactive` is unchanged — it runs in
  the parent and claims no slots. The JSON return path is unchanged and pinned by a test:
  `RETURN CONTRACT: json`, `jq -e` validation, `INVALID_RETURN_FORMAT`, the `workers_run` proof gate
  and `verify-story-deliverables.sh` all still apply.

- promote 2026-09-11 (ralph orchestrator policy): the hard policy
  `ralph-orchestrator-context-discipline` no longer mandates a fresh worker per story. Rules 6 and 8
  previously required "one preflight explorer, one story worker per story" — which directly
  contradicted the session worker pool the orchestrator skills now use. They now require **one live
  slot per HQ worker id**, claimed through `core/scripts/conduct-pool.sh` and reused across stories,
  with compaction or recycling at cap rather than a new child each time. Two stories that classify
  to the same worker **serialize on that slot**; they do not get one each.
- promote 2026-09-11 (ralph orchestrator policy): everything that made the policy worth having is
  unchanged and is pinned by a test — `RETURN CONTRACT: json`, `jq` parsing, one retry,
  `INVALID_RETURN_FORMAT`, one-line narration, no parent phase simulation, bounded parent log reads,
  and budget-aware regression gates. Extra slots beyond one per worker still require a high-risk
  trigger or an explicit user opt-in after stating the token and runtime cost.
- promote 2026-09-11 (ralph orchestrator policy): the rationale is rewritten. Fresh-context-per-story
  is no longer presented as the token-saving mechanism; parent thinness, JSON returns and the pool
  cap are. Resuming a slot is now the point rather than a compromise — it reuses the prompt cache and
  keeps the worker identity the operator chose, where a cold start pays for both again every story.
- promote 2026-09-11 (ralph orchestrator policy): the policy `when:` trigger now covers `/conduct`
  and `/execute-task` alongside `/run-project` and `/run-pipeline`, so the JSON contract applies
  everywhere the pool is used to orchestrate.
- promote 2026-09-11 (ralph orchestrator policy): `core/knowledge/public/workers/README.md` records
  the divergence rather than leaving "Fresh context per task (no context rot)" reading as absolute.
  `/run-project --interactive` is unaffected and stays parent-driven.

## Release: v15.0.128-beta.1

- promote 2026-09-10 (Grok HQ execution): Grok sessions auto-bind `company_slug` + scope-capability on SessionStart from a safe source only (parent session, `HQ_SPAWN_COMPANY`, or already-written meta — never cwd guessing). Unbound company-path tools were the dominant Grok failure (mandatory-scope denials).
- promote 2026-09-10 (Grok HQ execution): `GROK_SESSION_ID` is a first-class session-id env var. Empty Glob/`list_dir` deny with "pass a scoped path" instead of the HQ-root timeout dump. SessionStart writes `workspace/sessions/<sid>/skill-catalog.txt`.
- promote 2026-09-10 (Grok HQ execution): headless Grok spawn (workflow-runner + fleet adapter) uses `--always-approve`, `--output-format json`, and `--json-schema` when the CLI supports it. `/conduct` detaches with `core/scripts/hq-detach.sh` (Python `os.setsid` on macOS; stock Darwin has no `setsid(1)`).
- promote 2026-09-10 (Grok HQ execution): new `.grok/rules/` notes for skill catalog, prompt-queue `task_already_running`, worktrees vs `repos/`, session bind, and MCP default-on (`hq-work` only in the project file). Operator action: disable or auth unused Superhuman MCP profiles in user Grok config if start banners bother you.
- promote 2026-09-11 (supply-chain guard): the `npm/pnpm/yarn/bun` install guard
  (`.claude/hooks/block-unsafe-package-install.sh`) no longer mis-reads the value
  of a space-separated flag as a package name. `npm i -g --prefix /path <pkg>`
  used to have `/path` treated as an untrusted positional package, which blocked
  the sanctioned first-party / allow-listed global install (e.g. upgrading the hq
  CLI into `~/.local`). Value-taking flags (`--prefix`, `-C`, `--registry`,
  `--cache`, `--dir`, ...) now have their value token skipped. The guard is
  unchanged for genuinely untrusted installs -- a new 12-case regression suite
  (`.claude/hooks/tests/block-unsafe-package-install.test.sh`) pins that
  `--prefix /path left-pad` still blocks. No operator action required.

## Release: v15.0.127-beta.6

- promote 2026-09-11 (conduct worker definitions): `/conduct` now **loads the worker it picks**.
  Previously the worker id was only a pool-slot label: the registry was consulted, a name was
  chosen, and then a generic lane was launched — so dispatching to `code-reviewer` and dispatching
  to `unmatched` produced identical lanes. `/conduct` now reads `{path}/worker.yaml` for the matched
  worker and builds the brief from it: the worker's name and description open the brief, its
  `instructions` are carried verbatim, and the paths to its `skills[].file`, `context.base` and
  `knowledge` entries are passed so the lane reads its own procedures. The lane's `timeoutSecs` now
  comes from `execution.max_runtime` instead of a fixed 15 minutes.
- promote 2026-09-11 (conduct worker definitions): a worker's `verification.approval_required` and
  `verification.human_checkpoints` are now **binding**. A worker that declares
  `before_merge_production` has that checkpoint carried into its brief as an explicit
  stop-and-report, and the parent asks the user before telling the lane to proceed. A declared human
  gate that does not happen is a defect, not a shortcut.
- promote 2026-09-11 (conduct worker definitions): the Step 2 selection filter was unfollowable. It
  told the agent to consider workers "whose `scope` is the active company, `public`, or personal",
  but registry entries have never carried a `scope` field — they carry `company`, `visibility` and
  `team`. The filter is now written against the real fields: `status` must be `active`, and
  `company` must be empty (a core or personal worker, available to every tenant) or exactly the
  active company slug. An entry naming a different company is out of scope, stated as a tenancy
  boundary rather than a preference.
- promote 2026-09-11 (conduct worker definitions): `execution.model`, `codex_model` and
  `codex_flags` are deliberately NOT applied. They name models for a delivery path `/conduct` no
  longer uses; the engine is the operator's session-wide choice and the tier follows the task.
- promote 2026-09-11 (conduct worker definitions): `context.base` paths are resolved before they
  reach the brief rather than passed through. They are not uniformly rooted — some are relative to
  the HQ root, some to `core/` — and many are stale: of 175 distinct entries shipped today, 109
  resolve from the HQ root, 17 only under `core/`, and 49 point at nothing at all. Each entry is
  tried against the HQ root, then `core/`, then the worker's own directory, and an entry that
  resolves nowhere is dropped instead of being handed to the lane as a missing path.
  `skills[].file` needs no such treatment: all 44 shipped entries resolve against the worker's own
  directory.
- promote 2026-09-11 (conduct worker definitions): new test
  `core/scripts/tests/conduct-worker-selection.test.sh` pins the skill to both schemas it reads, and
  parses the detached lane launch at **both** levels — the outer script and the inner `bash -c`
  body. An unbalanced quote inside that body is just a character to the outer shell, so it survives
  an ordinary syntax check and only fails at dispatch, in a detached process whose output goes to a
  log nobody is watching yet.

## Release: v15.0.127-beta.5

- promote 2026-09-11 (conduct lane drop box): a `/conduct` lane is no longer sealed once it
  launches. Every lane now carries a drop box, and a hook inside the lane delivers from it on
  the lane's next tool event, so a correction reaches a worker **while it is still working** —
  no kill, no relaunch, no waiting for the task to finish.
  `bash core/scripts/conduct-inbox.sh send --run-dir <dir> --text "..."` queues a message; the
  lane picks it up on its next tool call and treats it as an operator instruction outranking
  its brief. The channel is one-way: the lane cannot reply, and its answer still arrives in its
  final output. Messages queue, so sending before the lane's first tool call is safe, and each
  is delivered exactly once with the consumed copy retained under `inbox/claimed/` as a record
  of what the lane was actually told.
- promote 2026-09-11 (conduct lane drop box): **every engine is reachable mid-task, but not the
  same way.** Codex and Claude lanes take the message quietly on `PostToolUse`, as context before
  the model's next step, with `Stop` as a backstop for anything queued late. Grok cannot be handed
  context on any event — its adapter routes passive-hook output to diagnostics and cannot block a
  `Stop` — so a Grok lane is reached on `PreToolUse` instead: the message arrives as a denied tool
  call whose reason is the text, and the lane is told the call was not blocked on its merits and to
  retry. That costs the interrupted call, so prefer Codex for work you expect to steer often. Grok
  deny reasons truncate near 1200 characters; keep messages to that engine short.
- promote 2026-09-11 (conduct lane drop box): a message is only ever consumed on an event that can
  actually reach the model. Draining on an event that cannot would not delay it — it would destroy
  it, silently, while the operator believed a correction had landed. The lane exports
  `HQ_CONDUCT_ENGINE` at launch so the hook can tell which route applies; a lane predating that
  export is treated as Codex.
- promote 2026-09-11 (conduct lane drop box): new script `core/scripts/conduct-inbox.sh`
  (`send | drain | list | clear`) and new hook `.claude/hooks/conduct-lane-inbox.sh`, registered in
  `.claude/settings.json` on `PostToolUse` (matcher `*`), `Stop`, and `PreToolUse` for the six tool
  matchers Grok dispatches (Bash, Read, Write, Edit, Grep, Glob), and allowlisted in all three
  `hook-gate.sh` profiles. The hook is gated on `HQ_CONDUCT_RUN_DIR`, which only a `/conduct` lane
  exports, and exits before touching disk when that variable is absent — so it is inert in every
  ordinary session despite the wildcard matcher, and it never blocks a lane that is legitimately
  finished.

## Release: v15.0.127-beta.2

- promote 2026-09-10 (conduct worker pool): `/conduct` no longer starts a new in-session
  subagent for every task. Each task is now matched to a long-lived HQ worker from a capped
  session pool and run as a detached `core/scripts/workflow-runner.mjs` lane on a chosen
  engine (Codex, Grok, or Claude) — the same runner `/orchestrate` already uses. Two things
  change for you. Lanes are ordinary OS processes, so they survive a compaction or a session
  restart, and `/conduct` now works on hosts with no in-session subagent support at all.
  And the number of live children is bounded: typical 8 or fewer, worst case
  `CONDUCT_POOL_CAP` (default 8), instead of one per task. Fifty tasks map onto at most
  eight workers.
- promote 2026-09-10 (conduct worker pool): new script `core/scripts/conduct-pool.sh` —
  `list | assign | record | recycle | clear` over the `conduct_pool` list on
  `workspace/sessions/<id>/meta.yaml`. `assign` is the only command that decides anything:
  it returns spawn or resume, retires the least-recently-used idle worker when the pool is
  full, and refuses without changing anything in two cases: exit 3 when every slot is
  running, and exit 4 when the requested worker's own lane is still going (only an idle slot
  is resumable — relaunching into a live lane's run directory would overwrite the artifacts
  of a process still working). Every read-modify-write holds a per-session lock for the whole
  transaction, because `/conduct` dispatches independent tasks concurrently and the atomic
  file replace at the end is not enough on its own. Override the cap with `CONDUCT_POOL_CAP`. The pool is deliberately not written through `hq-session.sh set`,
  which replaces a single-line `key: value` and cannot round-trip a nested list.
- promote 2026-09-10 (conduct worker pool): the session key `/conduct` persists is now
  `conduct_engine` (codex, grok, or claude), replacing `conduct_agent` (grok, opus, gpt,
  claude-*), which named in-session subagent types that no longer exist on this path. A
  session still carrying `conduct_agent` is harmless — `/conduct` ignores it and asks once
  for an engine. `/conduct off` clears both the pool and the engine.
- promote 2026-09-10 (conduct worker pool): `/run-project` inline and ralph modes are NOT
  changed in this release and still spawn per story; `/run-project --interactive` is
  unchanged. Catalog suggest-create is not part of this work.

## Release: v15.0.126-beta.2

- promote 2026-09-09 (goals and tasks board): tasks are a first-class list on the board
  rather than user stories inside a standing bucket project. A board's `tasks[]` holds
  loose work with its own small shape (`id`, `title`, `description`,
  `status: open|blocked|done`, `priority`, `objective_id`, `criteria[]`, `contacts[]`);
  `prd.json` user stories remain the shape for project-scoped work. This drops the
  `metadata.kind: "task_board"` bucket convention introduced in v15.0.126-beta.1 — a
  bucket project never completes and pollutes the project registry, and `prd.json`
  carries `branchName` / `e2eTests` / `files` / `dependsOn`, none of which mean anything
  for an errand.
- promote 2026-09-09 (goals and tasks board): the owner's board is `personal/board.json`
  in the overlay at the HQ root, not under `companies/personal/`. The personal vault's
  `.hqinclude` allowlist does not cover the reserved personal company scope, so a board
  kept there is invisible to an agent reading that vault; `personal/board.json` must
  itself be listed in `.hqinclude`. `core/scripts/hq-task.sh` gains
  `list|add|done|block|reopen|goals`, defaults to `personal/board.json`, and takes
  `--company <slug>` for `companies/<slug>/board.json`. Corrects the default and the
  guidance shipped in v15.0.126-beta.1. Anyone who created a bucket project under that
  release should move its stories into their board's `tasks[]` and delete the bucket;
  other companies are unaffected.

## Release: v15.0.126-beta.1

- promote 2026-09-09 (goals and tasks board): new concept doc
  `core/knowledge/public/hq-core/goals-and-tasks-board.md` — documents the three-layer
  pattern for recording intent on a company board (objectives and key results in
  `board.json` v2 → projects → tasks as `prd.json` user stories), the standing
  "task bucket" convention for errands too small to deserve a project
  (`metadata.kind: "task_board"`, conventionally named `life-admin`), and the read/write
  contract an agent follows when working a board. No new file formats; it reuses
  `board.json` v2 and ordinary project `prd.json` files, so existing board tooling needs
  no changes.
- promote 2026-09-09 (goals and tasks board): new scripts `core/scripts/hq-task.sh` and
  `core/scripts/hq-task.mjs` — `hq-task.sh list|add|done|reopen` manages tasks on a standing
  task-bucket project without hand-editing `prd.json`, assigning story ids and keeping the
  story shape consistent. Defaults to `--company personal --project life-admin`; works
  against any company and bucket name. No action required; existing projects are untouched
  unless the script is pointed at them.
- promote 2026-09-08 (access ladder): new core skill `.claude/skills/hq-access/SKILL.md`
  — `/hq-access <path-or-query>` diagnoses a vault file you cannot find or open as exactly
  one of never-existed / not-synced / no-access, fetches and pins when you have access,
  repairs sync when the fetch fails, and asks the prefix owner for a read grant after one
  confirmation via a DM with a one-click `hq files share` prompt. Runs `hq access` from
  `@indigoai-us/hq-cli` >= 5.109.0 and falls back to the same ladder over existing
  commands on older CLIs. No action required; upgrade the CLI to get the native command.
- promote 2026-09-08 (access ladder): new hard policy
  `core/policies/hq-failed-file-open-runs-access-ladder.md` — a failed Read/cat/open of a
  `companies/<slug>/…` path must run `/hq-access` before replying "file does not exist".
- promote 2026-09-08 (access ladder): `hq-files`, `hq-sync`, and `hq-heal` skills gain
  one-to-two-line pointers at `/hq-access`; `hq-heal` gains an `access` error class whose
  recipe is the ladder. No behavior change for existing flows.
- promote 2026-09-08 (quick reference): `core/knowledge/public/hq-core/quick-reference.md` gains an `hq access <path-or-query>` row in the `hq files` table. Docs only.

## Release: v15.0.121-beta.8

- promote 2026-09-04 (work-mesh progress noise): `core/scripts/work-mesh.mjs`
  — `report` / `progress` / `story` with no `--summary` and no task transition
  no longer post a thread event (local skip note, exit 0); task-only moves post
  a specific synthesized line (`US-003 → doing: <title>`); identical summaries
  for the same project within 10 minutes are coalesced client-side via
  `~/.hq/work-mesh/cache/last-progress.json`; the "Project work is in
  progress." / "Work is underway." placeholders are removed. **Impact:** skills
  that called `report` without a summary now produce no channel row
  (intended); board moves are unaffected. No action needed.
- promote 2026-09-04: policy `hq-project-work-mesh-reporting` bumped to v3 —
  progress reports must carry a real summary. No action needed.

## Release: v15.0.120-beta.7

- **Desktop sessions now get named on the first turn:** outside the terminal
  CLI the hook's `sessionTitle` never lands — the desktop host keeps its own
  title store and honours only its auto-titler and the model's
  `set_session_title` call. The three earlier session-title fixes therefore
  only ever reached terminal sessions. In `mode: full` the hook now injects a
  one-time instruction on the first user prompt telling the model to name the
  session immediately in HQ grammar, carrying the company/project the hook
  already resolved (or asking it to derive both from the message when nothing
  resolved). It never fires on SessionStart, in `mode: auto`, or once a session
  has been renamed by hand. No action needed.

## Release: v15.0.120-beta.4

- **HQ no longer names sessions `chat`:** when the hook could resolve neither a
  project nor a repo for a session, it emitted whatever was left — a bare
  command word (`chat`, `startwork`) or a lone org token (`HQ`). That is worse
  than silence twice over: it overwrites the host's written summary ("HQ core
  skill cloning") with a word that distinguishes nothing, and because the stub
  never changes, the wrapper's change-only cadence then keeps the session quiet
  for the rest of its life. Sessions were sitting on 1281 prompts still titled
  `chat`. The helper now prints nothing in that state, so the host's own title
  stands; the moment a project or repo resolves, HQ takes the title back. No
  action needed, and sessions that already resolve a project are unaffected.

## Release: v15.0.120-beta.4

- **New `/conduct` skill:** orchestrator mode that dispatches every task to a
  background worker agent on a user-chosen model (grok, opus, gpt, or native
  Claude opus/sonnet/haiku) so the parent session stays free to accept and
  route new messages. No migration steps required.

## Release: v15.0.120-beta.3

- **Desktop sessions no longer lose HQ naming permanently:** the one-time free
  pass that lets HQ ignore Claude Desktop's built-in auto-titler required proof
  that the title came from the session transcript. A desktop auto-title
  *inherited on resume* arrives in the `session_title` SessionStart input, when
  the transcript is often unreadable — the path may be absent, or the title line
  not yet flushed. Proof failed, the pass was withheld, and the session was
  muted for good with no `.autoname` file left behind to explain why. Resumes
  may now claim the pass unproven; `startup` (where `claude --name` is the only
  way a title can exist before any turn) and all other events still require
  proof, so `--name` and mid-session `/rename` back off exactly as before.

- **Sessions already muted by that bug now heal themselves:** the manual-rename
  marker short-circuits before any of the fixed logic runs, so affected sessions
  would have stayed muted forever. A mute carrying no `.autoname` sibling whose
  live title is in HQ grammar is provably wrong — a real rename is free-form
  prose — and is now cleared automatically so naming resumes. Mutes on prose
  titles, and mutes with a spent free pass (the documented second-rename
  back-off), are left untouched. No action needed.

## Release: v15.0.120-beta.2

- **First session title no longer drops the project:** `UserPromptSubmit` hooks
  run in parallel, so the session-title hook regularly computed its title before
  `auto-session-project` had written the session's project marker. The result
  was a projectless stub (`HQ`, `chat`) on a session's first prompt that only
  self-corrected on the following prompt. The hook now waits up to 2s — once per
  session, guarded by a `.projwait` state flag — for that marker before
  computing the title. Sessions that resolve no project pay the wait a single
  time, never per prompt. No configuration change; no action needed.

## Release: v15.0.117-beta.1

- **Session naming reminder now reaches the assistant:** the session-title
  grammar policy only triggered on prompts containing `session-title` or
  `rename`, words that do not occur in ordinary use, so the assistant was
  never told to name the session and titles fell back to the host autoname.
  The policy is now a per-session baseline (`on: [SessionStart]`,
  `when: always`) and states plainly that outside the terminal CLI — notably
  the Claude Code desktop app, which ignores `hookSpecificOutput.sessionTitle`
  and tracks sessions under its own ids — `set_session_title` is the only
  mechanism that names a session. Honouring `enabled`/`mode` in
  `settings/session-title.yaml` is unchanged; no action needed.

- **Claude Desktop auto-titler no longer disables HQ session naming:** Claude
  Desktop's built-in session auto-titler writes titles indistinguishable from
  a manual rename, which permanently tripped HQ's rename back-off on every
  desktop session. The session-title hook now ignores the first non-HQ title
  seen in a session's transcript (the auto-titler) and retakes the title; a
  second, different non-HQ title still counts as a real rename and backs off.
  New `desktop_autoname` key in `settings/session-title.yaml`
  (`ignore-first` default · `respect` restores the old behavior). No action
  needed unless you prefer the desktop auto-titler — then set
  `desktop_autoname: respect` in `personal/settings/session-title.yaml`.

- **Session title grammar reworked (supersedes the version shipped in
  v15.0.95-beta.1):** titles are now `{glyph} {COMPANY} · {subject}` with
  **exactly one** glyph, chosen by a four-tier precedence ladder — first tier
  that applies wins.

  1. *Needs you or finished* — 🙋 waiting on the user, 🤝 handed off to a person
     or fleet agent, 📤 closed with a handoff to resume from, ✅ shipped,
     🧊 parked.
  2. *Long-running by nature* — 🔁 recurring loop, 💬 standing channel.
  3. *Workflow stage* — 💭 exploring, 📐 planning, ⚡ building, 👀 in review,
     🧪 verifying.
  4. *Craft* — 🎨 design, ⚖️ legal, 💰 money, 📊 data, 🔎 research, 🔒 access,
     🛠️ tooling, ✍️ writing, 📣 growth, 🤖 agents, 📱 mobile, 🏗️ architecture,
     🧭 strategy, 🐛 incident, 🎟️ client, 🎤 music and events. This tier is open
     and is rendered *instead of* a stage glyph when the craft is the more
     interesting fact.

  v15.0.95-beta.1 shipped a `{icon} {CATEGORY} · {subject} · {phase}` form whose
  category token conflated two axes — sometimes a domain, sometimes a company —
  and fell back to a placeholder `🟦` when neither applied. The company now
  always leads the text and is never substituted with a generic token; when no
  company resolves, the token is omitted. `✅`, `📤` and `🤝` are three distinct
  states and are not collapsed: the work shipped, the session closed with
  resumable state, someone else owns it.

  **⛔, 🚫 and ⚠️ are banned by name** for "waiting on the user". A session with
  a question is working correctly; routinely spending a hazard glyph on a normal
  condition is how a warning stops meaning anything.

  `core/scripts/session-title.sh` emits a tier 2 or tier 3 glyph, the company
  and a slug. It never emits 🙋 (it cannot know that) and never a craft glyph —
  its only subject is a directory slug, so any keyword match against that slug
  would be redundant with the slug by construction. Both are left to the
  assistant, which sets a written subject via `set_session_title` once the
  session's purpose is clear.

  No action required for existing installations. Titles already emitted in the
  superseded form are replaced on the session's next title change; there is no
  migration step and no stored state to clear.

- **Session auto-naming is now a setting you can turn off:**
  `core/settings/session-title.yaml` ships the defaults; copy it to
  `personal/settings/session-title.yaml` to change them.

  - `enabled: false` — HQ never touches a session title. Claude Code's own
    auto-naming still applies; this switch turns off HQ's layer, not all naming.
  - `mode: auto` — the hook only. Titles are derived mechanically from the
    project path and the active slash command, and the assistant never renames.
  - `mode: full` (default) — the hook names the session immediately and the
    assistant replaces the directory slug with a written subject.

  Resolution is env → `personal/settings/` → `core/settings/` → built-in
  defaults, so the existing `HQ_SESSION_TITLE=off` and
  `HQ_DISABLED_HOOKS=session-title` escape hatches still win over both files.
  `HQ_SESSION_TITLE=auto` is new and selects `mode: auto` for one shell.
  Resolution is exposed as `core/scripts/session-title-config.sh`, which prints
  `enabled=` and `mode=`; it is grep/sed only, so the hook path stays free of
  both python3 and node.

  The same file carries an `aliases:` block mapping long company slugs to short
  forms (`aliases: {some-long-slug: SHORT}`). Without an entry a slug renders as
  its first hyphenated token, upper-cased and capped at 8 characters. HQ ships
  no company names in that block by design — release code must not carry tenant
  slugs — so put yours in `personal/settings/`, which is never released.

  No action required for existing installations; the defaults preserve current
  behaviour.

- **Session titles carry the repo or product, and a handoff shows two states:**
  the grammar is now `{glyph} {COMPANY} · {Product} · {subject}`. The product
  slot is optional and sits before the subject so identity survives truncation —
  a sidebar shows roughly 33 characters. It is derived from the session cwd when
  that sits inside `repos/`, with a leading company word dropped (under company
  `HQ`, the repo `hq-work` renders as `Work`). Omit it when the company has only
  one product or the subject already names it.

  `/handoff` now distinguishes 📝 *wrapping up* (the handoff is being written)
  from 📤 *handoff ready* (the session is closed; resume from the thread). The
  hook emits 📝 because that is what the running command tells it; the assistant
  sets 📤 once the handoff has actually landed. Both remain distinct from ✅ (the
  work shipped) and 🤝 (a person or agent owns it).

## Release: v15.0.114-beta.2

- **Codex no longer forces Extra High reasoning for every HQ task.**
  `.codex/config.toml` no longer sets `model_reasoning_effort`, so each install
  inherits the operator's user-level choice or per-task selection. Existing
  tasks retain their current setting; new tasks stop being forced to `xhigh`.

## Release: v15.0.110-beta.3

- **`/delegate` grants + reachability probe: three false-negative bugs fixed.**
  (1) The vault-grant verifier now recognizes a recipient email that the vault
  resolves to a `personUid` — it was grepping the ACL read-back for the literal
  email and so false-failed every fully-provisioned member (only pending
  invites, which stay email-keyed, ever passed). It now diffs the prefix's
  direct grants before/after the share and is resolution-aware. (2) The
  reachability probe browses each parent prefix once (memoized) with a retry on
  a throttled empty page, instead of re-browsing per referenced file. (3) Its
  file-presence check is now pipe-free, fixing a `set -o pipefail` + `grep -q`
  SIGPIPE false-negative that marked a genuinely-present file "not in the vault"
  whenever it sorted early in a large parent listing. No action required; the
  scripts are replaced on `/update-hq`.

## Release: v15.0.110-beta.1

- **Hook timeouts raised to a 30s floor: a 5s budget was silently disabling
  guards.** Every hook budget in `.claude/settings.json` dated from when hooks
  were pure bash. Several are now Node-backed — the checkpoint Stop gate
  delegates to `hq core checkpoint-stop-gate` — and Node startup alone can
  exceed 5s on a loaded box. A hook killed at its timeout emits nothing, and no
  output means **allow**, so an expired budget does not fail loudly: it turns
  the hook off.

  Measured on one live session (2026-08-20), hooks killed at their timeout:
  `block-core-writes-bash` 217x (worst 15.2s), `block-hq-worktree-session`
  155x (12.7s), `protect-core` 74x (14.9s), `block-hq-root-git-mutation` 45x
  (10.0s), `block-unsafe-package-install` 34x (11.2s),
  `mandatory-scope-authorizer` 25x (10.8s), `detect-secrets` 12x (10.0s),
  `checkpoint-stop-gate` 4x (7.4s). Most of those are guards; the scope
  authorizer is the one just hardened to fail **closed** for cross-tenant
  safety, and a timeout kill bypasses it before that logic runs.

  Every budget under 30s is now 30s (85 at 5/10/15s, plus the four 20s
  `reindex.sh` registrations). The deliberately-long budgets (60s, 300s) are
  unchanged. This costs nothing in the normal case — the Stop gate measures
  1.4s on the real dispatch path, 1.5s with a cold capability cache — and only
  matters under load, which is exactly when a guard should complete rather than
  be skipped. `core/scripts/tests/hook-timeout-floor.test.sh` pins the floor so
  a new registration cannot reintroduce a budget a Node-backed hook cannot meet.

  Not fixed here: `inject-policy-on-trigger` already had a 60s budget and still
  timed out at 70.4s. Raising it further would stall a prompt for over a minute,
  so it needs a performance fix rather than more budget.

## Release: v15.0.106-beta.1

- **The in-tree checkpoint Stop gate is now a delegating shim; the logic lives
  only in the CLI.** `.claude/hooks/checkpoint-stop-gate.sh` shipped a full,
  behavior-identical copy of the gate as a transitional fallback for CLIs
  predating `hq core checkpoint-stop-gate` (hq-cli 5.99.0, 2026-08-11). The
  duplication cost what duplication costs: the copies drifted — the CLI ran
  three fixes behind at one point — every change needed a matched pair of PRs,
  and each repo grew a suite whose real job was detecting the drift. The hook
  is now ~70 lines: probe the CLI once per version, hand over stdin, emit the
  CLI's decision verbatim.

  **Impact on update:** if the installed CLI cannot provide the gate (no `hq`
  on PATH, or a build older than 5.99.0), the gate no longer runs at all —
  the hook emits no decision and the turn ends normally, per the
  never-strand-a-session doctrine that governs every other error path in this
  hook. Previously such an install fell back to the in-tree copy. The CLI
  self-updates, so this affects only an install that is both very stale and
  not updating; `hq doctor` reports it and `hq self-update` fixes it. Note
  that the opt-in company-scope requirement
  (`HQ_CHECKPOINT_SCOPE_GATE_DOMAINS`) rides the same gate and is therefore
  also inactive on such an install — it is off by default in release-shipped
  scaffold, so only deployments that configured it are affected.
  `HQ_CHECKPOINT_GATE=0` remains the supported kill switch;
  `HQ_CHECKPOINT_GATE_NO_CLI=1` now means the gate does not run at all rather
  than "use the in-tree copy".

- **The Stop gate now requires a user-facing reply, not just the checkpoint:**
  the checkpoint payload is read by a background maintenance agent and never by
  the human, but agents kept treating it as the report — writing rich
  `--summary/--decision/--next` flags and then ending the turn on the tool
  call with a stub reply or none at all. A transcript audit of 1471 stop-gate
  checkpoint turns (2026-08-19) found 2.7% ended with no user-facing reply
  anywhere. Guidance alone could not fix this: the CLI's post-checkpoint
  reminder arrives after the agent has already decided to end the turn.
  The gate now measures the assistant text the genuine turn delivered after
  its last *work* tool call — on either side of the checkpoint, and across the
  gate's own block feedback — and, when a satisfying checkpoint leaves that
  under `HQ_CHECKPOINT_REPLY_MIN` non-whitespace characters (default 80),
  blocks **once** with a dedicated "deliver your reply now" message. An agent
  that already replied is never asked to restate (no double-messaging);
  mid-turn status notes written before the last work tool do not count as the
  reply. The nudge is stamped per checkpoint tool id and counted against the
  shared consecutive-block loop guard (hq-cli 5.103.8: at most 3 consecutive
  blocks per session, then the gate fails open until an allowed Stop resets
  the counter), so no combination of demands can strand a session.
  `--gate-probe` never triggers it, `--idle` triggers it only when the turn
  ran other tools, and the Codex runtime is excluded (its Stop feedback has
  its own delivery contract). It composes with the reply-aware block variants
  from hq-cli #417: an unsatisfied turn whose reply is already visible is told
  to checkpoint and stop — never to repeat itself — while an unreplied turn is
  told to checkpoint first and reply as the turn's final text.

  This behavior ships in the CLI (`hq core checkpoint-stop-gate`, hq-cli
  #415) and reaches operators with the CLI update, not with this scaffold
  release; the shim above is what routes to it. No action required on update.
  Operators who want the old behavior can set `HQ_CHECKPOINT_REPLY_MIN=0`;
  `HQ_CHECKPOINT_GATE=0` still disables the whole gate.

## Release: v15.0.105-beta.1

- **New `/hq-checkup` command: one manual health check that also repairs.**
  HQ previously had no single answer to "is my HQ working?". `hq doctor` covers
  hook wiring only; `/hq-heal` is reactive and needs an error already in hand;
  the CLI-version and hq-core-release facts existed only inside the advisory
  `check-hq-update.sh` SessionStart banner, which nobody could invoke on demand.
  `/hq-checkup` closes that gap. It verifies that the HQ CLI is installed and
  current, that hq-core is current, that the user is signed in, that the macOS
  menubar app and its background sync watcher are running, that cloud sync is not
  paused, that every workspace has backed up recently, that no sync conflicts are
  outstanding, and that the hook guardrails pass.

  It repairs by default rather than only reporting. Four remediations run
  automatically because each is safe and reversible: installing or updating the
  CLI, launching the menubar app, backing up stale workspaces one company at a
  time, and applying `hq doctor --fix`. After each repair it re-runs the original
  measurement and reports the true post-fix state, so a remediation that did not
  take is never announced as a success.

  Four conditions are deliberately left to the operator because no agent can
  perform them: signing in (a browser flow), un-pausing cloud sync (a menubar
  click), resolving conflicting file copies (only the operator knows which copy
  to keep), and running `/update-hq` (it rewrites the scaffold beneath a live
  session and must run in a fresh one).

  Findings that survive an attempted repair are demoted from the "Needs you"
  list to an informational line, so a permanently unfixable condition — an
  abandoned vault that no longer responds to sync — does not train the operator
  to ignore the whole report.

  All operator-facing output is written for a non-technical reader: no file
  paths, version numbers, process names, or HQ-internal vocabulary. `SKILL.md`
  carries a substitution table enforcing that ("hook" becomes "HQ's safety
  checks", "conflict" becomes "two copies of the same file").

  `check-hq-update.sh` is unchanged; the session-start nudge still fires
  independently, and `/hq-checkup` is the manual path to the same facts plus
  everything that hook does not cover.

  No action required on upgrade. Run `/hq-checkup`, or
  `bash .claude/skills/hq-checkup/hq-checkup.sh --check` to inspect without
  changing anything.

## Release: v15.0.103-beta.1

- **The scope guard's line-continuation defence worked only on Linux (SECURITY).**
  `mandatory-scope-authorizer.sh` strips backslash-newline before scanning a
  Bash command, because bash removes it before tokenizing — without that step a
  company path split across a line continuation is never reassembled. The strip
  was written as `${cmd//$'\\\n'/}`, and bash 3.2 — the stock macOS shell —
  matches that unquoted pattern against nothing: it reads the leading backslash
  as a pattern escape rather than a literal. The strip silently became a no-op,
  the scanner saw only the fragment before the break (an unknown company, so
  allowed) and never examined the rest, and the cross-company read the check
  exists to stop went through. bash 5 matches the same expression, so Linux CI
  stayed green while every macOS run of the covering test (`[9]`) failed.

  The pattern is now a quoted variable, which is literal on 3.2 and 5.x alike.
  `lint-shell-portability.sh` gained a rule for the whole class — an unquoted
  ANSI-C substitution pattern carrying a literal backslash — so the next one
  fails CI instead of shipping. Single-escape patterns (`$'\\t'`, `$'\\037'`)
  expand to one character, are unaffected, and are not flagged.

- **The scope-guard suite stopped writing into the developer's real HQ.** Case
  `[15]` invoked `hq-session.sh`, which resolves its root as
  `${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-<its own path>}}`. A developer running the
  suite from inside a Claude session inherits `CLAUDE_PROJECT_DIR` pointing at
  the real checkout, so the bind landed in that developer's own
  `workspace/sessions/` and the case failed locally. CI sets neither variable and
  fell through to the script's path, which is why it passed there. The case now
  pins both to the fixture.

  With this and the `[9]` fix, the suite passes end to end on macOS/bash 3.2 for
  the first time.

## Release: v15.0.101-beta.1

- **The company-scope guard now fails closed (SECURITY).**
  `mandatory-scope-authorizer.sh` decides whether a tool call may touch
  `companies/{co}/`. When the hook payload carried no session id it fell back to
  `workspace/sessions/.current` — a single, global, last-writer-wins pointer that
  names whichever session fired a hook most recently, not the caller. An agent
  the host could not name therefore inherited a stranger's company binding: an
  **unbound** spawned agent was observed reading another tenant's files because
  `.current` happened to name a session bound to that tenant (2026-08-19, HQ
  15.0.98, reproduced 2/2). A payload with no session id is exactly what
  `claude -p --session-id <uuid>` produces.

  The guard now accepts **only** the hook payload's session id. It consults
  neither `.current` nor the session environment: an id in the environment names
  whoever exported it, and a spawned agent inherits its parent's
  (`core/scripts/tests/hq-agent-session-hooks.test.sh` case 7 documents that
  inheritance), so trusting it would authorize a child against its parent's
  tenant. A call that cannot be attributed to a session is **denied** rather than
  guessed. This restores the invariant `core/scripts/lib/session-id.sh` already
  documents: "the enforcement side does not use .current. The scope guard …
  reads the authoritative session id out of the hook payload".

  Impact on update: a caller that reaches the guard with no identifiable session
  now gets a clear denial naming the cause, where it previously got silent
  access to company paths. Sessions identified by payload or environment are
  unaffected, as are `core/`, `personal/`, `repos/`, `workspace/`,
  `companies/manifest.yaml` and `companies/_template/`, which never required a
  binding.

- **`mandatory-scope-authorizer.test.sh` runs on macOS again.** `mktemp -d`
  returns `/var/folders/...` there while `/var` is a symlink to `/private/var`,
  and the hook resolves its own root with `pwd -P`; every absolute-path case
  then normalized to empty and the suite reported a pass-through as an allow.
  The fixture root is now canonicalized, the same way
  `core/scripts/tests/workflow-runner.test.sh` already does it. CI is unaffected
  (Linux `/tmp` is a real directory).


- **`/orchestrate` runs on the codex engine again:** codex forwards an
  `agent()` schema to its provider as a STRICT structured-output schema, which
  rejects any object node that omits `additionalProperties: false` or whose
  `required` does not list every property (HTTP 400 `invalid_json_schema`).
  The orchestrate pipeline's schemas set neither, so every codex launch died on
  its first agent (capture-idea) before doing any work. The workflow runner now
  rewrites each schema into the strict dialect on the wire
  (`core/scripts/lib/codex-output-schema.mjs`) and maps the answer back, so
  workflow scripts keep writing ordinary JSON Schema — an optional property
  stays out of `required` and comes back absent, not null — and the fix covers
  every present and future pipeline script, not just this one. The orchestrate
  pipeline's own schema literals also declare `additionalProperties: false`.
  No action required on update; the grok and claude engines are unaffected
  (they receive the script's schema in-prompt, unchanged).

- **Spawned workflow agents no longer lose their answer to the checkpoint
  gate:** an agent's whole contract is that its final text IS the return value,
  but HQ's end-of-turn checkpoint gate fires at Stop and demands one more turn
  after that answer is written. Observed 2026-08-19 on a claude-engine
  `/orchestrate` stage: the agent produced its JSON result, the gate fired, the
  agent ran `hq core checkpoint`, and the turn ended on that tool call — so the
  envelope came back with an empty result and the runner failed a stage that
  had really done ~8 minutes of work. `core/scripts/workflow-runner.mjs` now
  spawns every child with `HQ_DISABLED_HOOKS` extended by
  `checkpoint-stop-gate` (any value the operator set is preserved, not
  replaced). Checkpointing stays the launching session's job.

- **`/orchestrate` stages bind their company before reading it:** every stage
  runs as a fresh session, and a fresh session is unbound, so HQ's scope
  authorizer denies each read under `companies/{co}/` until
  `core/scripts/hq-session.sh set company_slug` runs — which nothing does for a
  spawned agent. Stages recovered on their own (the denial names its remedy)
  but burned turns doing it. The pipeline preamble now opens with the bind, and
  the "never retry a denied call" rule carves out this one denial, whose message
  states the exact fix. The personal scope is never told to bind.

## Release: v15.0.97-beta.2

- **Final-message placement contract (hidden-links fix):** the checkpoint stop
  gate now instructs runtimes to run the end-of-turn checkpoint FIRST and
  deliver the complete user-facing reply as the turn's final post-tool-call
  message (the Claude Code app folds pre-tool-call text into collapsed
  sub-messages, which was hiding links and instructions). Both HQ output
  styles (`hq.md`, `hq-operator.md`) gain a matching HARD placement rule.
  No action required on update; behavior-safe (the gate never mechanically
  required last-position).

## Release: v15.0.95-beta.1

- **Session titles now carry a category and an icon:** the SessionStart /
  UserPromptSubmit title hook emits `{icon} {CATEGORY} · {subject} · {phase}`
  (for example `🔒 SEC · vault-acl-risk-reconciliation · deploy`) instead of
  `{company} · {project} · {command}`. Three defects are fixed alongside it:
  `core/scripts/session-title.sh` no longer falls back to the machine-global
  `.claude/state/active-session-project` when a session has no project of its
  own (that fallback made every unpinned session inherit whichever project was
  last active anywhere on the box); its fallback HQ root is corrected from
  `$(dirname $BASH_SOURCE)/..` to `/../..`, which previously resolved to
  `core/` and made every state lookup silently miss whenever
  `CLAUDE_PROJECT_DIR` was unset; and `session-title` is added to
  `is_in_minimal_profile` in `.claude/hooks/hook-gate.sh`, where its absence
  made the hook a silent no-op under the minimal profile. Title ownership is
  now decided by grammar match rather than ledger membership alone, so a title
  set mid-session via `set_session_title` is recognised as HQ's own instead of
  being mistaken for a manual rename — previously the host's native session
  autonaming permanently disabled HQ titling for that session. Free-form prose
  titles are still treated as a user rename and still stop HQ from titling.
  New policy `hq-session-title-grammar` asks the assistant to replace the
  directory slug in the subject slot with a written subject once the session's
  purpose is clear. No action required for existing installations; stale
  `.claude/state/session-title-*.manual` markers may be deleted to re-enable
  titling on sessions that backed off under the old ownership test.

- **`/brainstorm` interviews properly again and stores research:** Step 3 is a
  decision-queue grilling — separate `AskUserQuestion` calls, one question at a
  time, covering every unresolved directional input (4-8 questions is normal;
  the prior "1 question max / skip if clear" behavior is removed). Step 4 now
  writes research notes to `{project_dir}/research/` (HQ landscape, market
  landscape, per-topic web notes) linked from brainstorm.md, and live web
  research is default-on for external-facing ideas. Pattern adapted from
  mattpocock/skills wayfinder. No action required for existing installations;
  the skill file is replaced on `/update-hq`.

## Release: v15.0.93-beta.1

- **Knowledge repositories must be real directories:** `/setup`, `/newcompany`,
  `/import-claude`, `/tutorial`, cleanup guidance, and the public README now use
  canonical real directories with optional embedded git. They no longer create or
  endorse repositories under `repos/` symlinked into `core/knowledge/`,
  `personal/knowledge/`, or `companies/{co}/knowledge/`. Existing installations
  with legacy knowledge symlinks should materialize the same content at the
  canonical path, preserve git there if needed, and verify `test -d PATH` plus
  `! test -L PATH` before the next cloud sync. `hq reindex` (hq CLI with the
  knowledge-migration pass) does this automatically: it scours the canonical
  knowledge locations, pulls each legacy repo, copies it inline with history
  preserved as an embedded repo, and removes the fully migrated legacy repo.

## Release: v15.0.91-beta.1

- promote 2026-08-12 (**Grok 4.6 workflow default**): the `/orchestrate` workflow runner
  (`core/scripts/workflow-runner.mjs`) now defaults its grok plan/exec tier models to
  `grok-4.6` (was `grok-4.5`), matching the newly released model. No action required — the
  defaults remain overridable via `HQ_WORKFLOW_GROK_PLAN_MODEL` / `HQ_WORKFLOW_GROK_EXEC_MODEL`,
  and reasoning effort is still inherited from the grok CLI config (`~/.grok/config.toml`),
  not set by the runner.

## Release: v15.0.88

- promote 2026-08-10 (**/deploy comments opt-in**): `/deploy` gains `--comments on|off`
  documenting turning the per-app comment widget on/off (`commentsEnabled`). The flag is
  orthogonal to the access mode and off by default — without it the deploy is byte-identical
  to a pre-feature deploy. A new Phase C step (`C.2.6`) PATCHes the per-app `commentsEnabled`
  flag after upload so the deploy pipeline injects the comment widget on the next deploy; a
  gated deploy's comment thread enforces the same access gate as the deploy itself.
