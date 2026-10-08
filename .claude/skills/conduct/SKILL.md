---
name: conduct
description: "Orchestrator mode: route every task to a pooled HQ worker lane on Codex, Grok, or Claude so this session stays free. Triggers: \"/conduct\", \"run everything in the background\"."
allowed-tools: Bash, Bash(bash core/scripts/conduct-pool.sh:*), Bash(bash core/scripts/conduct-inbox.sh:*), Bash(bash core/scripts/conduct-link.sh:*), Bash(bash core/scripts/conduct-lane-status.sh:*), Bash(bash core/scripts/hq-session.sh:*), Bash(HQ_SPAWN_COMPANY="$(bash core/scripts/hq-session.sh:*), Bash(HQ_SPAWN_PROJECT="$(bash core/scripts/hq-session.sh:*), Bash(HQ_SPAWN_TASK="$(bash core/scripts/hq-session.sh:*), Bash(bash core/scripts/resolve-company.sh:*), Bash(node core/scripts/workflow-runner.mjs:*), Read, Grep, Glob, AskUserQuestion, mcp__visualize__read_me, mcp__visualize__show_widget
argument-hint: "[engine] [task description] | adopt [session] | tell <child> <message> | status | off"
---

# Conduct — Orchestrate the Session Through Background Lanes

The parent session is the conductor. It triages first (`conductor-core.md`):
answers, lookups, reads, status, and one short skill stay inline; multi-file
edits, builds, long-running, multi-repo or multi-story work become lanes. For
lane work it writes briefs, launches lanes, relays results, and stays
responsive.

**Live children: typical ≤ 8, worst case `CONDUCT_POOL_CAP` (default 8).**
Every task is assigned to a worker in the session pool, so fifty tasks still map
onto at most eight lanes. Independent tasks share the pool; they do not each open
a new one. See `core/policies/subagent-fanout-budget.md`. Across sessions,
`CONDUCT_MACHINE_CAP` (default 16, `0` disables) bounds the running and claimed
lanes of every session pool on the machine; `assign` exits 6 past it, naming the
count, the cap and the sessions holding the most. A finished one-shot lane frees
its slot when it exits (dispatch protocol §5); `conduct-pool.sh reconcile` frees
any whose waiter was swept.

## Step 1: Parse the argument

- `off` → clear the pool and the mode, then say the session is back to doing work
  directly:
  ```bash
  bash core/scripts/conduct-pool.sh clear
  bash core/scripts/hq-session.sh set conduct_engine ""
  bash core/scripts/conduct-link.sh close 2>/dev/null || true   # only if a link is open
  ```
- `status` → report the pool, the live lanes, and any adopted sessions. No
  launch. See Step 6 and Step 7.
- `adopt` → open this session's link so sessions that are already running can
  join it as children. See Step 7.
- `tell {child} {message}` → send a message to an adopted session. See Step 7.
- First word matches a roster choice → persist it as the session default with
  `bash core/scripts/hq-session.sh set conduct_engine "{choice}"`. The remaining
  words are the first task.
- First word is not a roster choice → the whole argument is the task. Do not
  ask about engines here; the engine is resolved at first dispatch (below).
- No task text → confirm the mode and wait.
- Session opened with an `<auto-conduct>` block → the mode is the HQ default
  (`conduct.default_enabled: true` in `core/settings/orchestrator.yaml`, or the
  `personal/settings/orchestrator.yaml` override). The block is the conductor
  core (`conductor-core.md`): apply its triage rule, do not announce the mode,
  and do not ask about engines. The engine question is asked once, at the first
  task that actually needs a lane, unless the user named one. `/conduct off`
  still leaves the mode for the session.

## When a task needs a lane

Apply the triage rule from `conductor-core.md` first. A task that stays inline
never touches anything below this line. For a task that needs a lane:

1. Resolve the engine once per session, at this first dispatch, and persist it
   with `bash core/scripts/hq-session.sh set conduct_engine "{engine}"`:
   - `conduct_engine` already set → use it.
   - The user named a roster engine in this or an earlier message → use that.
   - Otherwise read `conduct.child_defaults` from `personal/settings/orchestrator.yaml`
     (falling back to `core/settings/orchestrator.yaml`). A row whose `main`
     matches this session's own model is applied silently; the engine is the
     one that serves that row's model (claude-* → `claude`, gpt-*/o* → `codex`,
     grok-* → `grok`).
   - No match → ask ONE `AskUserQuestion` (options: the engines whose CLI is
     actually installed, codex recommended), then persist the answer.
2. Read `.claude/skills/conduct/dispatch.md` whole and follow it: worker choice,
   pool slot, brief, detached launch, lane messaging, outcome verification, and
   the per-turn lane rows. It is not loaded for questions, lookups, status, or
   `/conduct off`, and nothing in it is needed until a lane exists.

## Step 7: Conduct sessions that are already running

Lanes are processes this session launched. The operator often also has other
sessions open — a Claude desktop session mid-refactor, a Codex or Grok session
in a terminal. Those can be **adopted**: each joins this session's link with
`/conduct-join`, and from then on this session instructs them and receives their
reports. The operator talks to one session instead of visiting each.

Adopted sessions are not pool lanes. They take no pool slot, this session did
not start them and must not stop them, and the pool cap does not count them.
What they share with lanes is the mailbox and the delivery hook.

### Open the link

```bash
bash core/scripts/conduct-link.sh open --engine "{this session's engine}" \
  --host-session "{this session's desktop id, when the host exposes one}"
# {"link":"cl-20260918-a1b2c3","join":"/conduct-join cl-20260918-a1b2c3"}
```

`open` is idempotent: a second call returns the same link. Then get the join
line into each session to adopt:

- **Claude desktop app** — find the session with
  `mcp__ccd_session_mgmt__list_sessions`, confirm with the operator which ones to
  adopt (one `AskUserQuestion`, multi-select), and send each the join line with
  `SendMessage` / `mcp__ccd_session_mgmt__send_message`. The target runs
  `/conduct-join` as its next turn. Never adopt a session the operator did not
  pick.
- **Anywhere else** — give the operator the join line to paste into that
  session. A Codex or Grok session in a terminal joins the same way.

Then start the waiter in the background, so a report wakes this session when it
is idle:

```bash
bash core/scripts/conduct-link.sh wait --timeout 3600   # run_in_background
```

It exits 0 when a report is pending and 3 on timeout. Either way, restart it
after handling what arrived, for as long as the link has children.

### Send an instruction

```bash
bash core/scripts/conduct-link.sh send --child "{name}" --text "{instruction}"
bash core/scripts/conduct-link.sh send --child all --text-file "{path}"
```

Delivery follows the child's engine exactly as in Step 5b: a Claude or Codex
child receives it as context on its next tool event, a Grok child by an
interrupted tool call. That reaches a child that is **working**. A child that is
idle has no tool events, so in the desktop app follow the `send` with one
session message to the child's `host_session` (from `list`) — `conductor: message
queued, run bash core/scripts/conduct-link.sh inbox` — which starts its next
turn. An idle terminal session picks the message up on its next turn; tell the
operator that, rather than implying it landed.

Write an instruction the way Step 4 writes a brief: the goal, the done criteria,
and what to report back. The child has its own context but not this
conversation.

### Receive reports

Reports arrive as `[conduct]` context on this session's tool events, each
labelled `[from {name} · {state}]`. On a host with no hooks, or when the waiter
fires, read them directly:

```bash
bash core/scripts/conduct-link.sh read
```

Handle a report the way Step 6 handles a lane result: verify a claimed result
independently before relaying it, send failures back to the same child, and
route every question for the operator through `/decision-queue` — then send the
answer back to the child that asked. When the transcript matters more than the
summary, read it with `mcp__ccd_session_mgmt__list_events`.

### Status

```bash
bash core/scripts/conduct-link.sh list
```

Render one row per child — name, engine, state, note, undelivered count — beside
the pool rows, in the same board widget when two or more things are in motion.

### Limits that are easy to get wrong

- **A child keeps its own company.** `list` shows each child's `company`. Never
  carry one child's findings, files or credentials into an instruction for a
  child bound to a different company. Relay to the operator instead.
- **Forwarded approval must be quoted.** A child treats an instruction as the
  operator speaking, but will not take an irreversible action on it unless the
  message quotes the operator's approval for that specific action. Ask the
  operator first, then quote the answer.
- **The mailbox is the record.** Session messages in the desktop app are
  wake-ups. Instructions and reports go through `conduct-link.sh`, so both sides
  and any later session can read what was said under
  `workspace/conduct-links/{link}/`.
- **Unattended sessions cannot be messaged** by the desktop tools. A scheduled or
  remote-dispatched session can still join and is reached through the hook only.

## Rules

- **The parent never blocks on a lane.** Launch detached, end the turn, let the
  waiter wake you.
- **Never use the `Agent` tool here.** Lanes are the dispatch mechanism, and they
  are what keeps the child count bounded and the session survivable.
- **The cap is mechanical.** `conduct-pool.sh` owns it. Exit 3 means stop, not
  "launch anyway".
- **Every owner-facing need goes through `/decision-queue`.** One
  `AskUserQuestion` per decision, on every surface — status ticks, loop wakeups,
  lane completions, cross-session requests — not only at session close. A
  markdown list of questions is a defect.
- **Every turn that ends with a lane running ends with one row per lane**
  (dispatch module, Step 7). A text-only reply with lanes running is a defect.
- **Irreversible actions stay with the user** — merging, publishing a release,
  force-pushing, deleting, sending messages. The lane prepares and reports; the
  parent asks once, then tells the worker to proceed.
- **Company context stays isolated.** One company per brief; resolve it before
  writing one.
- **Lanes commit their own work** with repo-anchored commands. The parent
  verifies from the artifacts, not from the report.
- **A message to a running lane is an instruction, not a note.** It outranks the
  brief on arrival, so send corrections and scope changes — not status questions,
  which the lane cannot answer.
- **Adopted sessions are steered, never owned.** This session did not start
  them: it does not stop, archive, rename or reconfigure them, and it adopts
  only sessions the operator named.
- **The mode persists for the session** in `workspace/sessions/<id>/meta.yaml`
  under `conduct_engine`, alongside the `conduct_pool` list. Later turns read
  both; `/conduct off` clears them.
- **The mode is the HQ default since v16.** `conduct.default_enabled: true` in
  `core/settings/orchestrator.yaml` (per-machine override:
  `personal/settings/orchestrator.yaml` with `default_enabled: false`) makes
  every fresh session start with the conductor core via
  `.claude/hooks/auto-conduct.sh`. Unattended sessions (local bots, fleet box
  turns, Outpost jobs, scheduled tasks, `HQ_UNATTENDED` /
  `HQ_SESSION_UNATTENDED` / `CLAUDE_HEADLESS`) are skipped; `HQ_AUTO_CONDUCT=1`
  plus a named engine opts one in. The engine is never
  preset; it is asked at first dispatch or named by the user. Per session: `HQ_AUTO_CONDUCT=1|0`
  or `HQ_DISABLED_HOOKS=auto-conduct`.

## See also

- `.claude/skills/conduct/dispatch.md` — the lane mechanics this skill loads at
  first dispatch
- `.claude/skills/conduct/conductor-core.md` — the always-on triage rule and
  intent-index pointer
- `/orchestrate` — takes one idea through the same runner from capture to
  finished deliverable, when the arc is known up front rather than arriving task
  by task
- `core/scripts/conduct-pool.sh` — the pool helper, including its cap semantics
- `core/scripts/conduct-inbox.sh` — the per-lane drop box behind Step 5b
- `/conduct-join` — the child's half of Step 7
- `core/scripts/conduct-link.sh` — the two-way mailbox behind Step 7
- `core/scripts/workflow-runner.mjs` — the multi-engine runner behind every lane
- `core/policies/subagent-fanout-budget.md` — why the cap is stated in the header
