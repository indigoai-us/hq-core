---
name: conduct
description: "Orchestrator mode: route multi-step work to in-session background subagents (default) or hq worker lanes. Triggers: /conduct, run everything in the background."
allowed-tools: Agent, SendMessage, Bash, Bash(hq lanes:*), Bash(bash core/scripts/lanes-workers.sh:*), Bash(bash core/scripts/hq-session.sh:*), Read, Grep, Glob, AskUserQuestion, mcp__visualize__read_me, mcp__visualize__show_widget
argument-hint: "[--workers <roles>] [--engine e] [--model m] [--effort f] | [engine] [task description] | adopt [session] | tell <child> <message> | status | off"
---

# Conduct — Orchestrate the Session Through Workers

The invoking session is the senior. `/conduct` hands each task to a worker and
returns so the senior session stays available. A worker is either a background
`Agent` subagent in this session (the default runner) or an `hq lanes` worker
lane (a separate process). Both runners get the same brief, the same done
criteria, and the same verification step. Worker mechanics load only when a
task needs a worker. Inline answers, lookups, reads, status, and one short
skill remain in this session.

### Runner choice

Owner decision, 2026-10-17: subagents are the default runner.

- `subagent` (default): the brief runs as a background `Agent` subagent in
  this session. It starts at once, uses this session's own Claude login, and
  is never refused for lane capacity. It shares this session's usage and stops
  if this session ends.
- `lane`: the brief runs through `hq lanes create`. Use it when the owner asks
  for lanes, when the work must outlive this session (overnight work, lead
  lanes that resume on their own, `--loop`, `--remote-control`, `--outpost`,
  or a non-Claude engine), or when the host has no `Agent` tool (Codex).
- A lane create that comes back with `no_account_with_room` or another
  admission or capacity refusal falls back to a subagent with the same brief.

Resolve the runner from the `conduct_runner` session pin, then
`conduct.runner` in `personal/settings/orchestrator.yaml`, then `subagent`.
See "Runner" in `dispatch.md`.

## Step 1: Parse the argument

- `off` → stop each lane this session launched after confirmation, clear the
  session engine pin, and close an open session link with
  `hq lanes link close --link <link-id> --session-id <session-id>`.
- `status` → report this session's lanes from `hq lanes list --json` and its
  running subagents; do not launch work.
- `--runner subagent|lane` → pin the runner for this session with
  `bash core/scripts/hq-session.sh set conduct_runner <runner>`. The remaining
  words are the task.
- `adopt` → use `.claude/skills/conduct/adopt.md` for linked-session behavior.
- `tell {child} {message}` → send through `hq lanes link send` with the same
  link, child, session, and text flags:
  `hq lanes link send --link <link-id> --child <child> --session-id <session-id> --text <message>`.
- `--workers {roles}` with optional `--engine`, `--model`, `--effort` → pin
  the selected provider/model/effort once for this session using
  `bash core/scripts/lanes-workers.sh setup`. The remaining words are the task.
- An explicit `--engine`, `--model`, or `--effort` applies to this session and
  overrides its existing pin. Mark `conduct_default_source` as `explicit`.
- An account the user names for the session is stored as
  `conduct_child_account` with `hq-session.sh set`, next to
  `conduct_child_model` and `conduct_child_effort`. With no account pin and no
  `--account` flag, every lane is created with `--account auto`. See
  `dispatch.md`.
- When a create or route response lists a signed-out account under
  `skipped[]`, raise one exec-bus owner card per account with the `fix`
  command, deduped for 24 hours in one machine-wide file. Never run
  `hq capacity login` or sign an account in or out. See "Signed-out
  accounts" in `dispatch.md`.
- Otherwise, use an existing `conduct_engine` as-is. Codex SessionStart may
  provide `conduct_engine=codex` and the selected `conduct_child_model` and
  `conduct_child_effort`; when no model is supplied, leave it unset for the
  CLI's documented fallback.
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

Read `.claude/skills/conduct/dispatch.md` whole and follow it. It covers the
runner choice, worker selection, the shared lane mapping, task briefs,
subagent dispatch, lane creation, watcher setup, role lanes, QA, CI, result
verification, and status rows. It is not loaded for questions, lookups,
status, or `/conduct off`.

## Rules

- `/conduct` creates workers only: background subagents or worker lanes. The
  invoking session is the senior; do not create manager or senior lanes.
- `hq lanes create` owns lane admission and capacity. On a capacity refusal,
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
- Owner-facing decisions use one structured question at a time.
- Every turn that ends with a worker running includes one status row per lane
  or subagent.
- Do not merge or publish from `/conduct`; the senior reviews and owns that step.
- Keep company context isolated. Resolve the company before writing a brief.
- A message to a running lane is an instruction. Send corrections, not status
  questions.

## See also

- `.claude/skills/conduct/dispatch.md` — lane mechanics
- `.claude/skills/conduct/conductor-core.md` — always-on triage rule
- `.claude/skills/conduct/adopt.md` — linked sessions
- `.claude/skills/conduct/roles/` — role templates for `--workers`
- `core/scripts/lanes-workers.sh` — role setup, templates, QA decision, and CI
- `.claude/skills/_shared/lane-dispatch-protocol.md` — shared lane mapping
