---
name: conduct
description: "Orchestrator mode: route every task to a pooled HQ worker lane on Codex, Grok, or Claude so this session stays free. Triggers: \"/conduct\", \"run everything in the background\"."
allowed-tools: Bash, Bash(bash core/scripts/conduct-pool.sh:*), Bash(bash core/scripts/conduct-inbox.sh:*), Bash(bash core/scripts/conduct-lane-status.sh:*), Bash(bash core/scripts/hq-session.sh:*), Bash(HQ_SPAWN_COMPANY="$(bash core/scripts/hq-session.sh:*), Bash(HQ_SPAWN_PROJECT="$(bash core/scripts/hq-session.sh:*), Bash(HQ_SPAWN_TASK="$(bash core/scripts/hq-session.sh:*), Bash(bash core/scripts/resolve-company.sh:*), Bash(node core/scripts/workflow-runner.mjs:*), Read, Grep, Glob, AskUserQuestion, mcp__visualize__read_me, mcp__visualize__show_widget
argument-hint: "[engine] [task description] | status | off"
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
  ```
- `status` → report the pool and the live lanes. No launch. See Step 6.
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
- **The mode persists for the session** in `workspace/sessions/<id>/meta.yaml`
  under `conduct_engine`, alongside the `conduct_pool` list. Later turns read
  both; `/conduct off` clears them.
- **The mode can be the HQ default.** `conduct.default_enabled` in
  `core/settings/orchestrator.yaml` (per-machine override:
  `personal/settings/orchestrator.yaml`) makes every fresh session start with
  the conductor core via `.claude/hooks/auto-conduct.sh`. The engine is never
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
- `core/scripts/workflow-runner.mjs` — the multi-engine runner behind every lane
- `core/policies/subagent-fanout-budget.md` — why the cap is stated in the header
