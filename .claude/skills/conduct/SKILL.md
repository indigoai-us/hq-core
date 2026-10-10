---
name: conduct
description: "Orchestrator mode: route multi-step work to worker lanes through hq lanes. Triggers: /conduct, run everything in the background."
allowed-tools: Bash, Bash(hq lanes:*), Bash(bash core/scripts/lanes-workers.sh:*), Bash(bash core/scripts/hq-session.sh:*), Read, Grep, Glob, AskUserQuestion, mcp__visualize__read_me, mcp__visualize__show_widget
argument-hint: "[--workers <roles>] [--engine e] [--model m] [--effort f] | [engine] [task description] | adopt [session] | tell <child> <message> | status | off"
---

# Conduct — Orchestrate the Session Through Worker Lanes

The invoking session is the senior. `/conduct` creates worker lanes through
`hq lanes`, arms a watcher, and returns so the senior session stays available.
Lane mechanics load only when a task needs a worker. Inline answers, lookups,
reads, status, and one short skill remain in this session.

## Step 1: Parse the argument

- `off` → stop each lane this session launched after confirmation, clear the
  session engine pin, and close an open session link with
  `hq lanes link close --link <link-id> --session-id <session-id>`.
- `status` → report this session's lanes from `hq lanes list --json`; do not
  launch work.
- `adopt` → use `.claude/skills/conduct/adopt.md` for linked-session behavior.
- `tell {child} {message}` → send through `hq lanes link send` with the same
  link, child, session, and text flags:
  `hq lanes link send --link <link-id> --child <child> --session-id <session-id> --text <message>`.
- `--workers {roles}` with optional `--engine`, `--model`, `--effort` → pin
  the selected provider/model/effort once for this session using
  `bash core/scripts/lanes-workers.sh setup`. The remaining words are the task.
- An explicit `--engine`, `--model`, or `--effort` applies to this session and
  overrides its existing pin. Mark `conduct_default_source` as `explicit`.
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

## When a task needs a lane

Read `.claude/skills/conduct/dispatch.md` whole and follow it. It covers worker
selection, the shared lane mapping, task briefs, lane creation, watcher setup,
role lanes, QA, CI, result verification, and lane status rows. It is not loaded
for questions, lookups, status, or `/conduct off`.

## Rules

- `/conduct` creates worker lanes only. The invoking session is the senior;
  do not create manager or senior lanes.
- `hq lanes create` owns admission and capacity. A capacity refusal leaves the
  task queued for a later tick; do not rebuild a pool around it.
- Arm a watcher for every lane before returning. Read the JSON envelope and
  verify the artifacts when the lane finishes; a process exit alone is not a
  delivery result.
- For Codex, generate a unique round ID and capture a fresh UTC `since`
  timestamp before every dispatch. Arm one completion watcher per round,
  including when a lane is reused. See `dispatch.md` for the command and event
  behavior.
- Owner-facing decisions use one structured question at a time.
- Every turn that ends with a lane running includes one status row per lane.
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
