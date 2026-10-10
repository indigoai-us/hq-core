# Conduct dispatch — worker lanes

This module applies only after the conductor decides work needs a lane. Lanes
are workers; the invoking session is their senior. Use the shared mapping in
`.claude/skills/_shared/lane-dispatch-protocol.md` and the same lifecycle used
by `/execute-task` and `/run-project`.

## Engine roster

Resolve `claude`, `codex`, or `grok` once for the session. A user-named engine,
model, or effort wins; otherwise use an existing `conduct_engine` as-is. A
fresh Codex session may already have `conduct_engine=codex` and selected model
and effort from its SessionStart payload. If that payload has no model, leave
the model unset. Otherwise use the session's matching `conduct.child_defaults`
row. Ask once if no provider is configured or available. Persist any explicit
choice with `hq-session.sh`.

## How work leaves this session

1. Resolve the active company, project, story, and worker profile. Reuse an
   existing lane under this senior when its repo and task fit. Check
   `hq lanes list --json --senior session:<session-id>` first.
2. Write the complete task brief to a file. Include done criteria, company and
   repo paths, constraints, required tests, and the JSON envelope path.
3. Create a worker lane using the mapping below. Keep HQ root as the CLI cwd.
   ```bash
   hq lanes create --company <company> --project <project> --story <story> \
     --worker <worker> --brief-file <brief> --senior session:<session-id> --json
   ```
   Add `--provider` from `conduct_engine`, `--model` from
   `conduct_child_model`, and `--effort` from `conduct_child_effort` whenever
   those session pins are set, for every `/conduct` lane. A user flag overrides
   the matching session pin. A repeated create for the same worker and
   senior continues its prior lane thread. If the lane is live, send follow-up work with
   `hq lanes message <lane> --text <instruction>`.
4. Parse the JSON response. Admission and capacity refusals keep the task
   queued for the next tick. Do not start a substitute process or pool.
5. Immediately before every `hq lanes create`, generate a unique `round_id`
   and capture the round baseline `since` in UTC seconds. After the create
   returns its lane id, arm one Codex watcher for that lane and round:
   ```bash
   round_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
   since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   hq lanes create ...
   bash core/scripts/lanes-completion-watch.sh start --lane <lane-id> \
     --provider codex --session-id "$CODEX_SESSION_ID" \
     --since "$since" --round-id "$round_id"
   ```
   Claude parents arm `Monitor(hq lanes watch <lane>)` or a bounded background
   `hq lanes wait` before returning.
   This starts a persistent `hq monitor` targeted to
   `session:codex:$CODEX_SESSION_ID`. The monitor command checks `hq lanes show`
   before waiting and after every bounded
   `hq lanes wait --any <lane> --for envelope --for state --for question --timeout <seconds> --json` result. It
   emits only an outcome at or after `since`. Receipt and monitor records are
   keyed by lane, `since`, and unique round ID, so separate dispatches in the
   same second still get separate records. Reusing the same round ID makes a
   repeated start idempotent. Arm one watcher per lane per round. Repeating a
   start suppresses duplicates within a round. Events include `since`, outcome,
   lane state, and the current envelope reference or worker log path. A different
   session id is rejected.
   If `hq monitor start` does not confirm acceptance, dispatch reports failure
   and does not claim a notification was scheduled. Codex has no idle wake; it
   sees the event on its next tool call or user message and cannot answer while
   idle. For multiple lanes, arm one watcher per lane. Do not branch on the CLI
   exit code alone.
The conduct lane inbox has no `SubagentStop` registration; child subagents
inside a worker do not deliver lane messages to the parent through that event.
6. On completion, read the lane's envelope through the CLI, inspect the changed
   files and commit, and verify claimed tests from their output. Report the PR,
   CI, artifacts, and any gap accurately.

## Step 2: Choose the worker

Read the worker registry and its worker definition. Match the task to the
worker's scope and skills. Consider only entries whose `status` is `active` and
whose `company` is empty or matches the active company; if the company field is
absent or names a different company, do not select that entry. The `--workers` mode uses
the role named by the user and that role's template under
`.claude/skills/conduct/roles/`; if none exists, use `generic.md`.

Resolve the active company with `bash core/scripts/resolve-company.sh` before
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
lane timeout.

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
creating the lane:

| Role | Worker profile |
|---|---|
| `backend` | `backend-dev` |
| `frontend` | `frontend-dev` |
| `designer` | `paper-designer` |
| `qa` | `qa-tester` |
| `orchestrator` | `architect` |

Other role names must match a registered worker profile. Each distinct role
must resolve to its own profile so the lane registry can preserve its thread.

## Step 3: Assign a pool slot

There is no conduct pool. `hq lanes create` is the admission operation and
applies hq-cli's provider, account, host, and lane capacity rules. If admission
returns `ok:false` with an admission or capacity code, leave the task queued.
Do not invent a second machine-wide cap or launch around the refusal.
Generate a unique
`round_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"` before each create,
then capture `since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"` immediately before the
call. This includes a repeated create that resumes a worker's existing lane. Pass both
values when arming the Codex watcher after the lane command returns.

## Step 4: Write the brief

Write a fresh, complete brief for each assignment, including the exact output
path and envelope contract. A role lane uses its role template as a starting
point, then receives the task-specific requirements and acceptance criteria.

## Step 5: Launch the lane, detached

Run `hq lanes create` from the HQ root with `--senior session:<this session>`.
Read the returned JSON for `ok`, `lane_id`, and any admission code. The CLI
launches asynchronously; do not wait in this session for the worker to finish.
Arm the watcher immediately.

### Tell and close linked sessions

Send and close operations use `hq lanes link send` and `hq lanes link close`,
with the existing link, child, session, text, and note flags. For example:
`hq lanes link send --link <link-id> --child <child> --session-id <session-id>
--text <message>`. Do not use a conduct-specific link wrapper.

## Step 5b: Send a message to a lane that is already running

Generate a unique `round_id`, then capture `since="$(date -u
%Y-%m-%dT%H:%M:%SZ)"` immediately before each `hq lanes message`. After the
command returns, arm a new round watcher with `bash
core/scripts/lanes-completion-watch.sh start --lane <lane> --provider codex
--session-id "$CODEX_SESSION_ID" --since "$since" --round-id "$round_id"`. Use
`hq lanes message <lane> --text <instruction>` (or `--text-file`) for a
worker lane. Use `hq lanes link send` for an adopted session. Include the
project and story flags when changing attribution. A live worker's message is
an instruction and may supersede its original brief.

## Step 6: Read the outcome, then verify it

Before answering a lane question or resuming a lane, generate a unique
`round_id`, then capture a fresh `since` immediately before the
`hq lanes questions answer` or `hq lanes resume` call. Afterward, start a new
Codex watcher for that lane round with `--since "$since" --round-id
"$round_id"`.

Use `hq lanes show <lane> --json` and the lane's envelope. Treat
`decision: "done"` as a report to verify, not proof by itself. Inspect the
branch diff, commit, PR, and exact CI head. For a `decision: "ask"`, deliver the
question and wait for an answer; for `blocked`, report the named blocker. A
lane's exit code never determines whether its artifacts were delivered.

## Step 6R: Role lanes (`/conduct --workers`)

Generate a unique `round_id` before every role-lane dispatch, then capture
`since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"` immediately before each create,
message, resume, or `hq lanes questions answer` call. After each call, start
one Codex completion watcher with that lane, `--since "$since"`, and
`--round-id "$round_id"`. This includes QA-failure returns and each CI-fix
round on a reused lane. Claude parents keep the `Monitor(hq lanes watch ...)`
path.

`--workers <roles>` creates one lane for each requested role. Pin provider,
model, and effort once per session and pass those pins to each
`hq lanes create`. Build each brief from the matching role template. The role
slot is one worker lane; create resumes that worker's previous lane thread when
possible. If it is still live, send the next instruction with `hq lanes
message`.

For a QA lane, use `lanes-workers.sh needs-qa`: frontend and designer roles
need QA; otherwise UI file extensions trigger it. After a lane opens a PR, use
`lanes-workers.sh ci` to read `gh pr checks` output. The check loop waits for a
stable set, fails closed on unreadable checks, and reports no checks separately
from pass. Count CI fix rounds with `lanes-workers.sh ci-round`; after the
configured maximum, return the decision to the operator rather than looping.
When `needs-qa` returns `yes`, create a `qa-tester` lane from the QA role brief,
send it the PR URL, and wait for its envelope. Return QA failures to the owning
implementation lane with `hq lanes message`; report the QA result with CI.

## Step 7: End every turn with one row per running lane

List lanes launched by this session with `hq lanes list --json --senior
session:<this session>`. For each active row include the lane id, worker,
state, `last_line`, PR, pending inbox count, elapsed time, and exit status when
present. Name the blocker on blocked or review work. Use a named reviewing
lane for `review` state.
