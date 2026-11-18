---
name: conduct
description: "Orchestrator mode: coordinate only; worker areas go to standing lanes on subagents or child sessions, small tasks to one-off subagents. Triggers: /conduct, run everything in the background."
allowed-tools: Agent, SendMessage, Bash, Bash(hq runners link:*), Bash(bash core/scripts/lanes-workers.sh:*), Bash(bash core/scripts/conduct-standing.sh:*), Bash(bash core/scripts/hq-session.sh:*), Bash(sh core/scripts/conduct-runner-resolve.sh:*), Read, Grep, Glob, AskUserQuestion, mcp__visualize__read_me, mcp__visualize__show_widget
argument-hint: "[--workers <roles>] [--engine e] [--model m] [--effort f] | [--runner runner] | [engine] [task description] | adopt [session] | tell <child> <message> | status | off"
---

# Conduct — Orchestrate the Session Through Workers

The invoking session is the senior. It coordinates and never does project
work itself. `/conduct` hands each task to a worker and returns so the senior
session stays available. Every worker gets the same brief, the same done
criteria, and the same verification step.

### Lanes

A lane is a standing worker with a role: an HQ worker from the registry, a
`--workers` role, or `generic`. It stays open and takes the follow-up tasks
for its area. In this default mode a lane is backed by one of:

- a named, resumable background `Agent` subagent. Send the next task with
  `SendMessage` to its agent id; resume or steer it the same way. Keep at
  most 5 to 8 lanes open at once.
- a conduct child desktop session that joined through `/conduct-join`, used
  when the area needs its own session. Talk to it over the conduct link.

Each lane is recorded as a `lane` object in
`workspace/orchestrator/conduct-subagents/<session-id>/runs.json` with
`lane_id`, `role`, `worker`, `standing: true`, `backing` (`subagent` or
`child-session`), `last_task`, and `state`. Default mode writes no lane
record under `workspace/lanes/`; its only lanes CLI is `hq runners link`.

The lanes Stop gate stays inert in default mode until a `workspace/lanes/lanes/`
record names this session as senior; an unreadable store gets one warning.

### Routing

Workers stay open. Route each task to the first match:

- Inline: an answer from context already loaded, or one status read.
- Lane: a task that matches an HQ worker or a `--workers` role, or an ongoing
  area in that worker's scope. Open the lane on the first such task and send
  later tasks for the same worker and company to it.
- One-off subagent: a small, bounded task with no matching worker (a lookup,
  a check, a draft, one skill run). It is not kept open.
- Child session: an area, or any work that must outlive this turn, that needs
  its own session.

`bash core/scripts/conduct-standing.sh route --kind <answer|status|lookup|small|ongoing>
[--worker <id> --company <slug>]` applies these rules for the session's
runner. `conduct-standing.sh agent-type --worker <id>` names the subagent type
for a lane. See "Default routing" in `dispatch.md`.

### Advanced mode: /conduct-runners

`/conduct-runners` is the advanced mode. There a lane runs as a runner: a
detached CLI process with admission, throttles, Outpost placement, keep-alive
across sessions, and non-Claude engines. Use it for overnight or away work,
`--loop`, `--remote-control`, `--outpost`, or a non-Claude engine. A Codex
host stays in default mode on `spawn_agent` / `wait_agent`.

The runner comes from `sh core/scripts/conduct-runner-resolve.sh`: a
`--runner` flag, then the `conduct_runner` session pin, then `conduct.runner`
in `personal/settings/orchestrator.yaml`, then
`core/settings/orchestrator.yaml` (ships `subagent`), then `subagent`. Set
`conduct.runner: runner` in personal settings to route every `/conduct` to
`/conduct-runners`. When the runner resolves to `runner`, read
`.claude/skills/conduct-runners/SKILL.md` whole and follow it instead of
this file.

## Step 1: Parse the argument

- `off` → after confirmation, mark each open lane in `runs.json` closed and
  stop resuming its subagent, run `bash core/scripts/conduct-standing.sh close`
  (it ends runner lanes an earlier turn or older core left open; with none it
  does nothing), clear the session engine pin, and close an open session link
  with `hq runners link close --link <link-id> --session-id <session-id>`.
- `status` → report lanes and one-off subagents from `runs.json` and child
  sessions from `hq runners link list`; launch nothing.
- `--runner runner` → pin it with
  `bash core/scripts/hq-session.sh set conduct_runner runner`, then read
  `.claude/skills/conduct-runners/SKILL.md` and hand the session to
  `/conduct-runners` with the remaining words as the task. `--runner mixed|lane`
  is read as `runner` for one release; say once that the name changed.
- `--runner subagent` → pin the default for this session. Board records for
  externally managed subagents belong to `/conduct-runners`.
- `adopt` → use `.claude/skills/conduct/adopt.md` for linked-session behavior.
- `tell {child} {message}` → send through `hq runners link send` with the same
  link, child, session, and text flags:
  `hq runners link send --link <link-id> --child <child> --session-id <session-id> --text <message>`.
- `--workers {roles}` with optional `--engine`, `--model`, `--effort` → pin
  the provider/model/effort once with `bash core/scripts/lanes-workers.sh setup`.
  It records one pending standing subagent lane per role in `runs.json`
  (never a runner lane); start each with the `Agent` tool on its first task.
  The six roles live in `.claude/skills/conduct/roles/`, shared with
  `/conduct-runners`. The remaining words are the task.
- An explicit `--engine`, `--model`, or `--effort` applies to this session and
  overrides its existing pin. Mark `conduct_default_source` as `explicit`.
  An engine other than the host's needs a runner; offer `/conduct-runners`.
- Otherwise, use an existing `conduct_engine` as-is. Codex SessionStart may
  provide `conduct_engine=codex` and the selected `conduct_child_model` and
  `conduct_child_effort`; a Codex host runs those subagents with `spawn_agent`
  / `wait_agent` and stays in default mode.
- If the user switches an automatic Codex engine to another engine without
  naming a model or effort, clear those automatic pins before setting the new
  engine and mark `conduct_default_source=explicit`. The `--workers` path does
  this in `lanes-workers.sh setup`; for a plain `/conduct` dispatch, clear the
  unset pins with `hq-session.sh` before saving the explicit values.
- A first word matching a provider choice sets the session default; otherwise
  treat the full argument as the task. Resolve an unpinned provider at first
  dispatch, asking once only when no configured default or installed provider
  matches.
- No task text → confirm conduct mode and wait.

## When a task needs a worker

Every task except an inline answer or status read needs a worker. Read
`.claude/skills/conduct/dispatch.md` whole and follow it; it starts from
`.claude/skills/_shared/conduct-dispatch-core.md`. Together they cover the
runner choice, lanes, worker selection, task briefs, subagent dispatch,
linked sessions, QA, CI, result verification, and status rows. They are not
loaded for questions, lookups, status, or `/conduct off`.

## Rules

- `/conduct` creates workers only: lanes, one-off subagents, or child
  sessions. The invoking session is the senior; do not create manager or
  senior workers.
- The conductor does no project work inline: no file edits, builds, tests,
  multi-step searches, or skill runs in this session.
- Resolve the company before writing a brief. A task with no company stays
  with the owner until one is named.
- Launch every subagent with `run_in_background: true`. Read the report and
  envelope and verify the artifacts when the worker finishes; a subagent's
  closing message alone is not a delivery result.
- Before `/handoff` or the session ending, mark the open lanes' `runs.json`
  rows closed, stop resuming their subagents, run `conduct-standing.sh close`,
  and say which lanes closed.
- On the first `/conduct` turn, run `conduct-standing.sh list`. If it names
  runner lanes, say so once and offer to close them with `conduct-standing.sh close`.
- Default `/conduct` opens and messages no runner lane. Its only `hq runners`
  command is `link`; `conduct-standing.sh close` only ends lanes already open.
- Owner-facing decisions use one structured question at a time.
- Every turn that ends with a worker running includes one status row per lane,
  one-off subagent, or child session.
- Do not merge or publish from `/conduct`; the senior reviews and owns that step.
- Keep company context isolated.
- A message to a running lane is an instruction. Send corrections, not status
  questions.

## See also

- `.claude/skills/conduct/dispatch.md` — default dispatch
- `.claude/skills/_shared/conduct-dispatch-core.md` — steps shared with `/conduct-runners`
- `.claude/skills/conduct/conductor-core.md` — always-on routing rule
- `.claude/skills/conduct-runners/SKILL.md` — advanced mode (runners)
- `core/scripts/conduct-standing.sh` — routing and agent types
- `.claude/skills/conduct/adopt.md` — linked sessions
- `.claude/skills/conduct/roles/` — role templates for `--workers`
- `core/scripts/lanes-workers.sh` — role setup, templates, QA decision, and CI
