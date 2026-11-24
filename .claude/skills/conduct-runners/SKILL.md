---
name: conduct-runners
description: "Advanced mode of /conduct: lanes run as runners (detached hq runners CLI processes) with admission, keep-alive, Outpost, and non-Claude engines. Triggers: /conduct-runners, /conduct --runner runner, overnight lanes."
allowed-tools: Agent, SendMessage, Bash, Bash(hq runners:*), Bash(bash core/scripts/lanes-workers.sh:*), Bash(bash core/scripts/conduct-standing.sh:*), Bash(bash core/scripts/hq-session.sh:*), Bash(sh core/scripts/conduct-runner-resolve.sh:*), Read, Grep, Glob, AskUserQuestion, mcp__visualize__read_me, mcp__visualize__show_widget
argument-hint: "[--workers <roles>] [--engine e] [--model m] [--effort f] | [engine] [task description] | adopt [session] | tell <child> <message> | status | off"
---

# Conduct runners — lanes on detached runners

`/conduct-runners` is the advanced mode of `/conduct`. The conductor is the
same: the invoking session is the senior, it coordinates and never does
project work itself, and every worker gets the same brief, done criteria, and
verification step. The difference is where a lane runs. Here a lane is a
standing worker with a role that runs on a runner: a detached `hq runners`
process under hq-cli admission, per-machine throttles, provider order, Outpost
placement (the user picks it: `core/policies/hq-lane-outpost-choice.md`), and
the Stop-gate contract. Background subagents still take small bounded tasks.

Default `/conduct` keeps lanes on resumable subagents and child sessions
(`.claude/skills/conduct/SKILL.md`). Use this mode for overnight or away work,
lead lanes that resume on their own, `--loop`, `--remote-control`,
`--outpost`, or a non-Claude engine. Codex runs default mode on `spawn_agent`.

### How a session gets here

- By name: `/conduct-runners <task>`.
- `/conduct --runner runner` (and `mixed` or `lane`, read as `runner` for one
  release). `/conduct` pins `conduct_runner=runner` and hands over.
- Automatically when `sh core/scripts/conduct-runner-resolve.sh` prints
  `runner`: a `--runner` flag, then the `conduct_runner` session pin, then
  `conduct.runner` in `personal/settings/orchestrator.yaml`, then
  `core/settings/orchestrator.yaml` (ships `subagent`), then `subagent`.

With no pin, first run `bash core/scripts/hq-session.sh set conduct_runner runner`.

### Routing

- Inline only: an answer from context already loaded, or one status read.
- Standing lane on a runner: any task that matches an HQ worker in the
  registry or a `--workers` role, and any ongoing area of work in that
  worker's scope. Open it early, keep it open with
  `hq runners keep-alive <lane> --on --standing`, and send later tasks for the
  same worker and company to the same lane instead of opening another.
- One-shot lane on a runner: work with no matching worker that must outlive
  this session or needs a non-Claude engine.
- Background subagent: a small, bounded task with no matching worker (a
  lookup, a check, a draft, one skill run). Register it with
  `hq runners create --runner subagent ...` so `hq runners list` stays the one
  view of this session's work, report progress and the final envelope with
  `hq runners progress <lane-id>`, and run the subagent through the host's
  `Agent` tool. The registration skips admission and starts no process;
  default `/conduct` never makes it.
- A lane create that comes back with `no_account_with_room` or another
  admission or capacity refusal falls back to a subagent with the same brief.

`bash core/scripts/conduct-standing.sh route --kind <answer|status|lookup|small|ongoing>
[--worker <id> --company <slug>]` applies these rules and names the standing
lane to reuse. `conduct-standing.sh send` opens or reuses the lane. See
"Runner rules" and "Standing worker lanes" in `dispatch.md`.

## Step 1: Parse the argument

- `off` → close the standing lanes with
  `bash core/scripts/conduct-standing.sh close` (keep-alive off, then
  interrupt, so a later create resumes the worker's thread), stop each other
  lane this session launched after confirmation, clear the session engine
  and `conduct_runner` pins, and close an open session link with
  `hq runners link close --link <link-id> --session-id <session-id>`.
- `status` → report this session's lanes from `hq runners list --json`, its
  standing lanes from `conduct-standing.sh list`, and its running subagents;
  do not launch work.
- `--runner subagent` → `bash core/scripts/hq-session.sh set conduct_runner
  subagent`, then read `.claude/skills/conduct/SKILL.md` (default mode).
- `board-record` → a detached board record for an externally managed
  subagent: `hq runners create --runner subagent ...` (this mode only).
- `adopt` → use `.claude/skills/conduct/adopt.md` for linked-session behavior.
- `tell {child} {message}` → send through `hq runners link send` with the same
  link, child, session, and text flags:
  `hq runners link send --link <link-id> --child <child> --session-id <session-id> --text <message>`.
- `--workers {roles}` with optional `--engine`, `--model`, `--effort` → pin
  the selected provider/model/effort once for this session using
  `bash core/scripts/lanes-workers.sh setup --runner runner`, then open one
  standing lane per role with `conduct-standing.sh send` before the first
  task. The role templates are the ones `/conduct` uses, in
  `.claude/skills/conduct/roles/`. The remaining words are the task.
- An explicit `--engine`, `--model`, or `--effort` applies to this session and
  overrides its existing pin. Mark `conduct_default_source` as `explicit`.
- An account the user names for the session is stored as
  `conduct_child_account` with `hq-session.sh set`, next to
  `conduct_child_model` and `conduct_child_effort`. With no account pin and no
  `--account` flag, every lane is created with `--account auto`. See
  `dispatch.md`.
- When a create or route response lists a signed-out account under
  `skipped[]`, ask the owner once per account with the `fix`
  command, deduped for 24 hours in one machine-wide file. Never run
  `hq capacity login` or sign an account in or out. See "Signed-out
  accounts" in `dispatch.md`.
- Otherwise, use an existing `conduct_engine` as-is. Codex SessionStart may
  provide `conduct_engine=codex` and the selected `conduct_child_model` and
  `conduct_child_effort`; when no model is supplied, leave it unset for the
  CLI's documented fallback.
- Switching an automatic Codex engine to another engine without a model or
  effort clears those automatic pins first (`lanes-workers.sh setup` does
  this for `--workers`) and marks `conduct_default_source=explicit`.
- A first word matching a provider choice sets the session default; otherwise
  treat the full argument as the task. Resolve an unpinned provider at first
  dispatch, asking once only when no configured default or installed provider
  matches.
- No task text → confirm the mode and wait.

## When a task needs a worker

Every task except an inline answer or status read needs a worker. Read
`.claude/skills/conduct-runners/dispatch.md` whole and follow it; it starts
from `.claude/skills/_shared/conduct-dispatch-core.md`. Together they cover
runner rules, standing lanes, worker selection, the shared lane mapping, task
briefs, lane creation, watcher setup, role lanes, QA, CI, result
verification, and lane rows. They are not loaded for questions, lookups,
status, or `/conduct-runners off`.

## Rules

- This mode creates workers only: lanes on runners or background subagents.
  The invoking session is the senior; do not create manager or senior lanes.
- The conductor does no project work inline: no file edits, builds, tests,
  multi-step searches, or skill runs in this session.
- Every lane is created with `--company <slug>`. Resolve the company first;
  a task with no company stays with the owner until one is named.
- Before `/handoff` or the session ending, run
  `bash core/scripts/conduct-standing.sh close` and say which lanes closed.
- `hq runners create` owns lane admission and capacity. On a capacity refusal,
  run the same brief as a subagent instead of queuing it; do not pick a lane
  account by hand or rebuild a pool around the refusal.
- Lanes never spend paid Claude extra usage unless the owner pins
  `conduct_allow_extra_usage=1`; only then pass `--allow-extra-usage`.
- Arm a watcher for every lane before returning; launch every subagent with
  `run_in_background: true`. Read the JSON envelope and verify the artifacts
  when the worker finishes; a process exit or a subagent's closing message
  alone is not a delivery result.
- For Codex, generate a unique round ID and capture a fresh UTC `since`
  timestamp before every dispatch. Arm one completion watcher per round,
  including when a lane is reused. See `dispatch.md` for the command and event
  behavior.
- A session joined to a conductor over a conduct link sends the same report
  shape as default `/conduct` (Step 6 and Step 7 of the shared core), so a
  super-conductor sweep reads both modes the same way.
- Owner-facing decisions use one structured question at a time.
- Every turn that ends with a worker running includes one status row per lane
  or subagent, rendered from `lane-rows.html` in this directory.
- Do not merge or publish from this mode. Keep company context isolated.
- A message to a running lane is an instruction. Send corrections, not status
  questions.

## See also

- `conductor-core.md` (always-on block for `runner`) and `lane-rows.html` here
- `.claude/skills/conduct/SKILL.md` — default mode (subagents and child sessions)
- `core/scripts/conduct-standing.sh` and `core/scripts/lanes-workers.sh`
- `.claude/skills/conduct/roles/` — role templates for `--workers`
- `.claude/skills/_shared/lane-dispatch-protocol.md` — shared lane mapping
