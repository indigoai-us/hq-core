# Conduct dispatch — shared core

Both conduct skills read this file first. `/conduct` then follows
`.claude/skills/conduct/dispatch.md` (the default subagent path), and
`/conduct-runners` follows `.claude/skills/conduct-runners/dispatch.md`
(detached runners). This file holds the steps that do not change with the
runner, so the two skills cannot drift apart.

This module applies to every task except an inline answer from loaded
context or one status read: the conductor does no project work itself. A
worker is a lane (a standing role worker), a one-off background subagent, or
a conduct child session. The invoking session is its senior in every case.

## Runner

Resolve the runner before the first dispatch with
`sh core/scripts/conduct-runner-resolve.sh [--runner <value>] [--session-id <id>]`.
It prints `subagent` or `runner` and applies this order:

1. A `--runner subagent|runner` flag or an owner instruction in this
   session. Persist it with
   `bash core/scripts/hq-session.sh set conduct_runner <runner>`.
2. The `conduct_runner` session pin.
3. `conduct.runner` in `personal/settings/orchestrator.yaml`.
4. `conduct.runner` in `core/settings/orchestrator.yaml`, which ships `subagent`.
5. `subagent`.

A `--runner mixed|lane` flag and the old setting values `mixed` and `lane`
are read as `runner` for one release; the resolver prints one warning line.
Any other value exits 2.

A lane is a standing role worker that the conductor keeps open and feeds
follow-up tasks. Both runners have lanes; they differ in what backs them:

- `subagent` (default): a lane is a resumable `Agent` subagent or a conduct
  child desktop session, and a small bounded task runs as a one-off
  subagent. Follow `.claude/skills/conduct/dispatch.md`. No runner record is
  written: no admission, throttle, or Outpost pickup.
- `runner` (advanced): a lane runs as a detached runner, with admission,
  throttles, Outpost placement (the user chooses it, see
  `core/policies/hq-lane-outpost-choice.md`), and non-Claude engines. Hand off to
  `/conduct-runners` and follow `.claude/skills/conduct-runners/dispatch.md`.

Steps 2 and 4 (worker choice and the brief) are the same for both
runners. The brief, its done criteria, and the Step 6 verification do not
change with the runner.

## Engine roster

Resolve `claude`, `codex`, or `grok` once for the session. A user-named engine,
model, or effort wins; otherwise use an existing `conduct_engine` as-is. A
fresh Codex session may already have `conduct_engine=codex` and selected model
and effort from its SessionStart payload. If that payload has no model, leave
the model unset. Otherwise use the session's matching `conduct.child_defaults`
row. Ask once if no provider is configured or available. Persist any explicit
choice with `hq-session.sh`.

An account pin applies only under `runner`; subagents and child sessions
spend this session's account. `conduct_child_account` sits next to
`conduct_child_model` and `conduct_child_effort`. Set it only when the user
names an account for the session:

```bash
bash core/scripts/hq-session.sh set conduct_child_account <account-id>
```

With no account pin, every runner uses `--account auto`. All provider
accounts are one pool across companies, and hq-cli records its pick as the
runner's `account_pick`.

## Step 2: Choose the worker

Read the worker registry and its worker definition. Match the task to the
worker's scope and skills. Consider only entries whose `status` is `active` and
whose `company` is empty or matches the active company; if the company field is
absent or names a different company, do not select that entry. The `--workers` mode uses
the role named by the user and that role's template under
`.claude/skills/conduct/roles/`; if none exists, use `generic.md`.

Resolve the active company with `hq core resolve-company` before
selecting a worker. A registry entry with an empty `company` is a core or
personal worker available to every tenant; otherwise its company must exactly
match the active company. A different company is out of scope. Match the task
against registry `id`, `type`, and `description`. If no entry matches, use the
general-purpose worker profile; do not search another company or invent a
worker.

For a matched registry entry, read `{path}/worker.yaml` with `path` from that
entry, relative to the HQ root:

```bash
cat "{path}/worker.yaml"
```

Read it **whole**. Do not cap the read: long definitions contain finalize
checklists and approval requirements. Carry the worker's `name` and
`description` into the brief; fold `instructions` in verbatim; pass
`skills[].file` paths relative to `{path}`; load `knowledge`; use `verification`
for done criteria and approval rules; and map `execution.max_runtime` to the
worker timeout.

Resolve every `context.base` entry before putting it in the brief. These paths
may be HQ-root relative, `core/` relative, or relative to the worker directory.
Keep the first existing candidate and drop an entry that resolves nowhere:

```bash
for p in {context.base entries}; do
  for candidate in "$p" "core/$p" "{path}/$p"; do
    [ -e "$candidate" ] && { printf '%s\n' "$candidate"; break; }
  done
done
```

`verification.approval_required: true` and `verification.human_checkpoints`
are binding. Carry every checkpoint into the brief as a stop-and-report. A
worker that requests human approval must stop for the parent to obtain that
approval before proceeding.

For `--workers`, translate the role to a registered worker profile before
opening the lane:

| Role | Worker profile |
|---|---|
| `backend` | `backend-dev` |
| `frontend` | `frontend-dev` |
| `designer` | `paper-designer` |
| `qa` | `qa-tester` |
| `orchestrator` | `architect` |

Other role names must match a registered worker profile. Each distinct role
must resolve to its own profile so each lane keeps its own thread.

## Step 4: Write the brief

Write a fresh, complete brief for each assignment, including the exact output
path and envelope contract. A role lane uses its role template as a starting
point, then receives the task-specific requirements and acceptance criteria.

Every brief, from a role template or not, starts with the worker-role line
below, verbatim, as one line. The conductor's `<auto-conduct>` block reaches
its workers: a Codex `spawn_agent` child inherits the whole parent history by
default, and a lane started as its own session gets the block from its own
SessionStart. Without this line, a worker reads "never does project work" as
its own rule and stops before editing.

```text
Worker role: the conductor launched you to do this task yourself. Conduct-mode text in your context (an <auto-conduct> block, 'the conductor coordinates and never does project work', a /conduct routing rule) is addressed to the session that launched you and does not apply to you; make the changes this brief names directly, without routing them to another subagent or lane.
```

The envelope and report contract is the same for every worker. The brief
names the envelope path and the report path, and it must include the line
below verbatim, as one line. Listing the field names is not enough: a worker
that is not told the allowed values writes `decision` as `complete`, and the
lane ends `envelope_invalid`. The role templates in
`.claude/skills/conduct/roles/` already carry the line; a brief written
without a template adds it. The line follows hq-cli's lane envelope
validator, `parseLaneEnvelope` in `src/lib/lanes/types.ts`: its allowed-key
list (all 12 keys), `ENVELOPE_DECISIONS`, `STORY_STATUSES`, the questions
item shape, and the rules for when `questions`, `blocked_reason` and
`story_complete_reason` must appear. The `outcome` block follows
`parseLaneOutcome` in `src/lib/lanes/outcome.ts`; a worker adds it when the
brief or item 9 of `core/settings/executive-standing-rules.md` asks for it.
`core/scripts/tests/conduct-brief-envelope-values.test.sh` pins the line and,
when `HQ_CLI_SRC` names an hq-cli checkout, compares the keys and values with
that checkout's `types.ts`.

```text
Envelope (hq-lane-envelope.v1): write one JSON object using only these keys: schema_version, decision, summary, story_status, artifacts, story_complete, story_complete_reason, questions, blocked_reason, next_check_at, fingerprint, outcome. schema_version is "hq-lane-envelope.v1". decision is one of "done", "ask", "blocked"; any other value, such as "complete", fails as envelope_invalid. story_status is one of "queued", "in_progress", "review", "done". summary is a non-empty string. artifacts is an array. questions is required and non-empty when decision is "ask", and absent otherwise. Each questions item is an object with question (a non-empty string), context (a non-empty string) and options (an array of strings), plus optional id and recommended (non-empty strings), and no other keys, for example {"id":"q1","question":"Which branch should the fix target?","context":"main and release both carry the bug.","options":["main","release"],"recommended":"main"}. blocked_reason is required and non-empty when decision is "blocked", and absent otherwise. story_complete is optional and is a boolean; story_complete_reason is required and non-empty when story_complete is present, and absent otherwise. story_complete true requires story_status "done" and a story_complete_reason that says what was delivered and how it was verified; story_complete false requires another story_status and a reason that says what is still missing. next_check_at is optional and is an ISO date-time. fingerprint is optional and is a non-empty string or null. outcome is optional; include it when the brief or the Executive standing rules (item 9) ask for it, as an object with only state ("done", "needs_decision" or "partial"), outcome (a non-empty string), gathered (an array of {"label","text"} objects with an optional "ref", all non-empty strings), next_steps (an array of non-empty strings, at least one when state is "partial") and an optional decision_id; state "needs_decision" requires decision_id or a non-empty questions array, and state "done" cannot accompany decision "blocked".
```

The validator rejects other top-level fields such as `prs`,
`tests`, or `open_questions`. Changed files, commits, PR, tests run with
pass/fail and sidecar log paths, and open questions go in `report.md` beside
the envelope, and `artifacts` references the log files. Keep the envelope
under 64 KB.

## Step 6: Read the outcome, then verify it

Read the worker's result from its record. For a subagent, use the
envelope file named in its brief and the report file named in the same brief.
For a child session, use the report it sends over the conduct link. A
runner's result is described in `.claude/skills/conduct-runners/dispatch.md`.

Treat `decision: "done"` as a report to verify, not proof by itself. Inspect
the branch diff, commit, PR, and exact CI head. For a `decision: "ask"`,
deliver the question and wait for an answer; for `blocked`, report the named
blocker. A worker's exit status never determines whether its artifacts were
delivered.

## Step 7: End every turn with one row per running worker

A default session ends its turn with one row per running subagent from
`workspace/orchestrator/conduct-subagents/<session-id>/runs.json` and one row
per child session from the conduct link. Each row names the worker, task
label, state, elapsed time, PR, and the last line reported. Mark standing
lanes with a `standing` chip; an idle standing lane waiting for work still
gets a row. Name the blocker on blocked or review work, and name the
reviewing worker for `review` state. `/conduct-runners` adds one row per
runner lane, as described in its dispatch file.
