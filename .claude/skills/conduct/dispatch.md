# Conduct dispatch — subagents and worker lanes

This module applies to every task except an inline answer from loaded
context or one status read: the conductor does no project work itself. A
worker is a background subagent in this session or an `hq lanes` worker lane;
the invoking session is its senior either way. Lanes use the shared mapping in
`.claude/skills/_shared/lane-dispatch-protocol.md` and the same lifecycle used
by `/execute-task` and `/run-project`.

## Runner

Resolve the runner before the first dispatch, in this order:

1. A `--runner mixed|subagent|lane` flag or an owner instruction in this
   session. Persist it with
   `bash core/scripts/hq-session.sh set conduct_runner <runner>`.
2. The `conduct_runner` session pin.
3. `conduct.runner` in `personal/settings/orchestrator.yaml`.
4. `conduct.runner` in `core/settings/orchestrator.yaml`, which ships `mixed`.
5. `mixed`.

Under `mixed` (the default, owner decision 2026-10-22):

- A task that matches an HQ worker or a `--workers` role goes to that
  worker's standing lane (see "Standing worker lanes"): opened on the first
  such task, reused for every later task for the same worker and company.
- Ongoing work with no matching worker, and every small bounded task with no
  matching worker (a lookup, a check, a draft), goes to a background
  subagent. `hq lanes create --worker` needs a registered worker, so there is
  no standing lane without one.
- Nothing runs inline beyond an answer from loaded context or one status read.

Under `subagent`, no standing lane is opened: every task is a subagent unless
one of the one-shot lane conditions below holds. Under `lane`, a task that
matches a worker uses that worker's standing lane and any other task gets a
one-shot lane.

Use a one-shot lane even when the runner is `subagent` when any of these hold:

- The work must outlive this session: overnight or away work, lead lanes
  that resume on their own, `--loop`, `--remote-control`, or `--outpost`.
- The engine is not Claude, or the host has no `Agent` tool (Codex sessions).
- The owner asked for a lane for this task.

Use a subagent even when the runner is `lane` when `hq lanes create` returns
`ok:false` with `no_account_with_room` or any other admission or capacity
code. Report the switch in one line, for example
`lanes refused (no_account_with_room, next reset <next_reset>); running as a subagent`.
Still raise the signed-out owner cards from the refusal's `skipped[]`.

`bash core/scripts/conduct-standing.sh route --kind <answer|status|lookup|small|ongoing>
[--worker <id> --company <slug>] [--outlives] [--engine <e>] [--runner <r>]`
resolves the runner as above, applies these rules, and prints `inline`,
`subagent`, `lane-reuse` (with the lane id), or `lane-open` (with
`standing`).

Steps 1, 2, and 4 (worker choice and the brief) are the same for both
runners. The brief, its done criteria, and the Step 6 verification do not
change with the runner.

## Standing worker lanes

Owner decision, 2026-10-22 ("Workers stay open"). A standing lane is one
worker lane per worker and company that stays open for the whole conduct run
and takes every task in its area.

1. Open early. As soon as the work shows which specialties it needs (or at
   `/conduct --workers`, one per role), open those lanes before the first
   task finishes, so later tasks find them ready.
2. Open or reuse with one command, from the HQ root:
   ```bash
   bash core/scripts/conduct-standing.sh send --worker <worker> \
     --company <company> --brief-file <brief> [--project <p>] \
     [--story <s> | --no-story <reason>] -- <pin flags>
   ```
   The `<pin flags>` are the `--provider`, `--model`, `--effort`, `--account`
   (or `--account auto`), and `--allow-extra-usage` flags from "How work
   leaves this session". When the session already recorded a lane for that
   worker and company and the lane can still take messages, `send` passes the
   brief with `hq lanes message <lane> --text-file <brief>` and prints
   `"action":"reused"`. Otherwise it runs `hq lanes create --company <company>
   --worker <worker> --keep-alive --senior session:<session-id>`, then
   `hq lanes keep-alive <lane> --on --standing` so the lane waits for queued
   work after every done turn, records the lane in
   `workspace/sessions/<session-id>/conduct-standing-lanes.json`, and prints
   `"action":"opened"`. A repeated create for the same worker and senior
   continues that worker's prior thread.
3. `--company` is required. Every lane is bound to its company
   (`hq-background-jobs-require-bound-company`), and a standing lane is never
   reused across companies.
4. Exit 3 means `hq lanes create` refused (capacity or admission). The create
   JSON is on stdout. Run the same brief as a subagent and report the switch
   in one line, as in "Runner".
5. Arm the watcher for the lane round as for any lane message or create
   (round id, `since`, `Monitor(hq lanes watch <lane>)` or the Codex watcher).
6. Close on `/conduct off`, `/handoff`, or when the owner says the area is
   finished: `bash core/scripts/conduct-standing.sh close` turns keep-alive
   off with `hq lanes keep-alive <lane> --off` and interrupts each lane with
   `hq lanes interrupt`, so the lane stays resumable for a later session.
   `--dry-run` lists what it would close. Use `conduct-standing.sh forget
   --lane <id>` to drop one lane from the record after closing it by hand.

`hq lanes doctor` and `hq lanes keep-alive-audit` report keep-alive lanes
blocked by retired, superseded, or pending-question state; run them in
`/conduct status` when a standing lane looks stuck.

## Subagent dispatch

1. Write the brief exactly as for a lane, to a file. The brief names the
   resolved company explicitly, and the subagent checks it against its own
   bound company before it starts. Name the envelope path
   `workspace/orchestrator/conduct-subagents/<session-id>/<run-id>/envelope.json`,
   where `run-id` is the round id below. Name the report path
   `workspace/orchestrator/conduct-subagents/<session-id>/<run-id>/report.md`
   in the same brief. The envelope uses the same fields as a
   lane envelope (`decision` of `done`, `ask`, or `blocked`, a summary, changed
   files, commits, PR, tests run with pass/fail and sidecar log paths, and open
   questions).
2. When the brief changes a repo, create a dedicated worktree on a feature
   branch before dispatch (`git -C <repo> worktree add -b <branch>
   workspace/worktrees/<name> origin/<base>`) and name it in the brief. Two
   running subagents never write the same files; overlapping work waits for
   the first subagent to finish.
3. Generate `round_id` and capture `since` as for a lane, then call the
   `Agent` tool with `run_in_background: true`:
   - `subagent_type`: from `bash core/scripts/conduct-standing.sh agent-type
     --worker <worker> --company <company>`. It returns the worker id when a
     Claude agent definition of that name exists (`.claude/agents/<id>.md`
     or the user's agents dir), otherwise `general-purpose`. For
     `general-purpose`, list the returned `worker_yaml` and `skill_files` in
     the brief and tell the subagent to read them first.
   - `model`: the family of `conduct_child_model` (`opus`, `sonnet`, `haiku`,
     or `fable`); omit it when no pin is set. Pass `effort` only when the
     owner set `conduct_child_effort` explicitly.
   - `description`: the worker name and a 3-5 word task label.
   - `prompt`: "Read <brief path> whole and follow it. Write the JSON envelope
     to <envelope path> before you finish, and a plain-text hand-back report
     of at most 200 lines to <report path> (`report.md` beside the envelope):
     outcome, changed files, commits, PR, tests run with pass/fail, and open
     questions. Keep the envelope under 64 KB: put full test or build output
     in a log file beside the envelope and name it from the envelope, never
     inline it. Commit your own work on the named branch. Do not push, open a
     PR, merge, or deploy unless the brief says so. Before you finish,
     wait for every background reviewer or subagent you started; never end
     while one is still running. End with a reply of at most 10 lines that
     names the envelope path and the report path."
4. Record the run in
   `workspace/orchestrator/conduct-subagents/<session-id>/runs.json`: agent
   id, worker, task label, brief path, envelope path, report path, worktree, `since`, and
   `round_id`. Write it through a temp file and `mv`.
5. Return to the owner. The app wakes this session when the subagent
   finishes; do not poll it. Send a correction to a running subagent with
   `SendMessage` to its agent id. That message is an instruction, as with
   `hq lanes message`.
6. On completion, read `report.md` and the envelope file, not only the
   closing message, and verify them as in Step 6. Never Read the harness's
   own task transcript (the `<agent-id>.output` JSONL the Agent tool writes
   under the user's `.claude/tasks/` folder): it is the raw tool log, grows to
   many MB, and the Read tool refuses it (feedback_49f72048). Everything the
   parent needs is in the report and the envelope. A missing envelope or
   report is a failed delivery: report it and resume the subagent once with
   `SendMessage` asking for both files. Delete the worktree only after its
   branch is merged or the owner drops it.

Subagent runs spend this session's Claude usage and stop if this session
ends. Keep long results in sidecar logs in the worktree and name those logs
from the envelope so they do not fill this session's context.

hq-cli 5.345.151 ships `hq lanes create --runner subagent`, which registers a
lane that an in-session subagent runs: it skips admission and starts no
process. Register each subagent run with it (with `--company`, `--worker`,
`--brief-file`, and `--senior session:<session-id>`) so the run shows in
`hq lanes list`, record the returned lane id in `runs.json`, and report the
result with `hq lanes progress <lane> --envelope <path>` (or `--failed
<reason>` when the subagent ended without an envelope). On an older hq-cli,
or when the registration fails, the status rows in Step 7 come from
`runs.json` alone.

## Engine roster

Resolve `claude`, `codex`, or `grok` once for the session. A user-named engine,
model, or effort wins; otherwise use an existing `conduct_engine` as-is. A
fresh Codex session may already have `conduct_engine=codex` and selected model
and effort from its SessionStart payload. If that payload has no model, leave
the model unset. Otherwise use the session's matching `conduct.child_defaults`
row. Ask once if no provider is configured or available. Persist any explicit
choice with `hq-session.sh`.

An account pin works the same way. `conduct_child_account` sits next to
`conduct_child_model` and `conduct_child_effort`. Set it only when the user
names an account for the session:

```bash
bash core/scripts/hq-session.sh set conduct_child_account <account-id>
```

With no account pin, every lane uses `--account auto`. All provider accounts
are one pool across companies, and hq-cli records its pick as the lane's
`account_pick`.

## How work leaves this session

1. Resolve the active company, project, story, and worker profile. A task in
   a worker area goes through "Standing worker lanes" above. For any other
   lane, reuse an existing lane under this senior when its repo and task fit.
   Check `hq lanes list --json --senior session:<session-id>` first.
2. Write the complete task brief to a file. Include done criteria, company and
   repo paths, constraints, required tests, and the JSON envelope path.
3. Create a worker lane using the mapping below. Keep HQ root as the CLI cwd.
   ```bash
   hq lanes create --company <company> --project <project> --story <story> \
     --worker <worker> --brief-file <brief> --senior session:<session-id> --json
   ```
   Add `--provider` from `conduct_engine`, `--model` from
   `conduct_child_model`, `--effort` from `conduct_child_effort`, and
   `--account` from `conduct_child_account` whenever those session pins are
   set, for every `/conduct` lane. A user flag overrides the matching session
   pin. When neither a `conduct_child_account` pin nor a user `--account` flag
   is set, pass `--account auto` so hq-cli picks the account with the most room
   from the shared pool. A repeated create for the same worker and
   senior continues its prior lane thread. If the lane is live, send follow-up work with
   `hq lanes message <lane> --text <instruction>`.
4. Parse the JSON response. An admission or capacity refusal, including
   `no_account_with_room` from `--account auto`, moves the task to a subagent
   with the same brief (see "Runner"). Report the switch and the soonest reset
   from `next_reset` in one line. When the task must outlive this session and
   cannot run as a subagent, keep it queued for the next tick instead and say
   `queued: no account has room until <next_reset>`. Never pick an account by
   hand to get around a refusal, and do not start a substitute process or
   pool. Pass `--allow-extra-usage` only when the session pin
   `conduct_allow_extra_usage` is `1`; it lets `--account auto` pick a Claude
   account whose plan limit is used up but whose paid extra usage is on,
   ranked last. Every create response can list
   signed-out accounts under `skipped[]`; raise one owner card per
   account as described in
   [Signed-out accounts](#signed-out-accounts-one-owner-card-per-account).
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

## Signed-out accounts: one owner card per account

`hq lanes create --account auto` and `hq capacity route --json` list every
account they passed over under `skipped[]`. The `no_account_with_room` error
carries `skipped[]` too. Read `skipped[]` on every create response, refused or
not, and on every `hq capacity route --json` this session runs.

A `skipped[]` entry is a signed-out account when both of these hold:

- `account` is a non-null lanes account id.
- `fix` is `hq capacity login <provider> --account <account>` for that same
  provider and account.

`hq capacity route` exists since hq-cli 5.345.111. The signed-out
`skipped[].fix` login command this step depends on exists in hq-cli 5.345.114
or newer. On an older hq-cli, a signed-out entry carries no login fix, so it
does not match and no card is raised.

An entry with the reason `no fresh reading (sign-in expired)` does not match.
Its `fix` is the plain `claude` open command for a Claude account (with
`CLAUDE_CONFIG_DIR` set for a non-default home), or null for other providers.
No card is raised for it. The account recovers on its own once the token
refresh succeeds or a lane runs on it.

Ignore every other entry, such as a sign-in that no lane account uses, a
usage-only reading, or a used-up limit. Those have no account or no login fix,
and `no_account_with_room` already covers running out of room.

Conduct never runs `hq capacity login`, never runs `--repair`, and never signs
an account in or out. It names the `fix` command and the owner runs it.

### The dedupe file

A signed-out account is one fact per machine, so one dedupe file serves every
project: `workspace/orchestrator/signed-out-cards.json`. Each project, story,
and lane the account blocked goes in that entry's `blocked[]` list. The same
account signed out under two projects raises one card.

The key is `<provider>:<account>`. Each entry stores the `reason` and `fix`
from the JSON, the exec-bus `card_id`, `raised_at`, `suppress_until`, the
`blocked[]` list, `rereads`, and `state` (`open`, `later`, or `disabled`).

For each signed-out entry:

0. An entry with `state` set to `disabled`: never raise, whatever its
   `suppress_until` or `reason` says, and do not change the entry. A disabled
   account that is also signed out still shows up under `skipped[]` with the
   same login fix, because hq-cli checks sign-in before it checks whether the
   lane account is enabled. Without this rule the card would come back every
   24 hours after the owner chose "Disable this account".
1. No entry under the key: raise a card and write the entry with
   `suppress_until` set to `raised_at` plus 24 hours.
2. An entry with a different `reason`: the reason changed, so raise a new card
   and replace the entry.
3. An entry with the same `reason` and the current time at or past
   `suppress_until`: raise again and reset `raised_at`, `suppress_until`, and
   `rereads`.
4. An entry with the same `reason` inside the window: do not raise. Add the
   project, story, and lane to `blocked[]` if they are not already there.

When a later create or route read lists the account in `ranked[]`, or no
longer lists it under `skipped[]`, the sign-out has cleared. Delete its entry
so the next sign-out raises a fresh card. A `disabled` entry is deleted only
when the account appears in `ranked[]`, which happens after the owner enables
it again and it is signed in. Its absence from `skipped[]` alone does not
delete it.

Write the file through a temp file in the same directory, then `mv` it over
the old one. Create `workspace/orchestrator/` if it is missing. If the file
does not parse, move it aside as `signed-out-cards.json.bad` and start from an
empty `cards` object.

### Raising the card

Raise with the executive bus, using this session's id:

```bash
bash personal/skills/executive/exec-bus.sh raise \
  --session-id <session-id> \
  --title "Sign back in: <provider> account <account>" \
  --question "Run: <fix>" \
  --option "I ran it|I signed the account back in" \
  --option "Later|Ask again in 24 hours" \
  --option "Disable this account|Stop routing lanes to it" \
  --context "Account <account> (<provider>) is signed out: <reason>. Blocked: <project> <story>, lane <lane-id>. Conduct never signs in for you; run the command yourself." \
  --blocked-work "<project> <story>, lane <lane-id>" \
  --blocking 0 --importance 3 --timeliness today
```

Store the returned card `id` as `card_id`. A lane that was refused stays
queued under the existing handling; the card does not change that. If
`personal/skills/executive/exec-bus.sh` does not exist on this machine, print
the same title, command, and context in this turn's status row and still write
the dedupe entry.

### Answers

The answer arrives in this session's executive inbox as
`Executive decision <card_id> ("Sign back in: ..."): <choice>`. Match the card
id to the dedupe entry.

- `Disable this account`: run `hq lanes accounts disable <provider> <account>`,
  then set `state` to `disabled` and record the time as `disabled_at`. Report
  the change in one line.
- `I ran it`: run `hq capacity accounts --json` once. If the account is signed
  in, delete the entry. If it is still signed out and `rereads` is 0, set
  `rereads` to 1 and raise the card once more with `Still signed out after you
  ran it.` at the start of `--context`. With `rereads` already 1, do not raise
  again until the reason changes or 24 hours pass. Do not loop on the re-read.
- `Later`: set `state` to `later` and `suppress_until` to the current time
  plus 24 hours.

### Worked example

`hq lanes create ... --account auto --json` returns this entry:

```json
{
  "provider": "claude",
  "account": "frog",
  "label": "frog",
  "organization": "Frogbear",
  "reason": "signed out: sign-in revoked",
  "fix": "hq capacity login claude --account frog"
}
```

The lane was for project `multi-provider-compute-router`, story `US-015`, lane
`01EXAMPLELANE`. The card reads:

```text
Title:    Sign back in: claude account frog
Question: Run: hq capacity login claude --account frog
Options:  I ran it | Later | Disable this account
Context:  Account frog (claude) is signed out: signed out: sign-in revoked.
          Blocked: multi-provider-compute-router US-015, lane 01EXAMPLELANE.
          Conduct never signs in for you; run the command yourself.
```

`workspace/orchestrator/signed-out-cards.json` after the raise:

```json
{
  "schema": "conduct-signed-out-cards.v1",
  "cards": {
    "claude:frog": {
      "reason": "signed out: sign-in revoked",
      "fix": "hq capacity login claude --account frog",
      "card_id": "dec-20261013101500-ab12",
      "raised_at": "2026-10-13T10:15:00Z",
      "suppress_until": "2026-10-14T10:15:00Z",
      "blocked": [
        {
          "project": "multi-provider-compute-router",
          "story": "US-015",
          "lane": "01EXAMPLELANE",
          "at": "2026-10-13T10:15:00Z"
        }
      ],
      "rereads": 0,
      "state": "open"
    }
  }
}
```

An hour later a lane for another project skips `claude:frog` with the same
reason. Conduct adds that project, story, and lane to `blocked[]` and raises
nothing.

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

This step applies to lanes only; subagents take no pool slot. There is no
conduct pool. `hq lanes create` is the admission operation and applies
hq-cli's provider, account, host, and lane capacity rules. If admission
returns `ok:false` with an admission or capacity code, run the task as a
subagent (see "Runner"), or leave it queued when it must outlive this session.
Do not invent a second machine-wide cap or start another lane around the
refusal. With `--account auto`, `no_account_with_room` means every account in
the pool is out of room. Report the soonest reset in one line. Do not choose
an account yourself.
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

For a lane, use `hq lanes show <lane> --json` and the lane's envelope. For a
subagent, use the envelope file named in its brief and the report file
named in the same brief. Treat
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

`--workers <roles>` opens one standing lane for each requested role with
`conduct-standing.sh send --worker <profile>`, using the role mapping in
Step 2. Pin provider,
model, effort, and account once per session and pass those pins to each
`hq lanes create`. With no account pin, pass `--account auto` to each one. Build each brief from the matching role template. The role
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

## Step 7: End every turn with one row per running worker

List lanes launched by this session with `hq lanes list --json --senior
session:<this session>`. For each active row include the lane id, worker,
state, `last_line`, PR, pending inbox count, elapsed time, and exit status when
present. Mark standing lanes from `conduct-standing.sh list` with a
`standing` chip; an idle standing lane waiting for work still gets a row.
Add one row per running subagent from `runs.json`, in the same row format,
with `subagent` as the runner chip, the agent id in place of the lane id, and
elapsed time from `since`. Name the blocker on blocked or review work. Use a
named reviewing lane for `review` state.

## Testing capacity distribution locally

To check that unpinned lanes spread across accounts, clear any
`conduct_child_account` pin and create two lanes with no `--account` flag, so
each create passes `--account auto`. Then run:

```bash
hq capacity route --json
hq lanes show <lane-1> --json
hq lanes show <lane-2> --json
```

Each lane's `account_pick` should name the account the router picked at the
moment that lane was created, with `account_source` set to `auto`.
`hq capacity route --json` shows the router's current pick, so run it right
after each create when comparing.

## Dry run: signed-out card

This walkthrough uses a fake `skipped[]` entry and a scratch copy of the dedupe
file. It raises no card and touches no account. Run it from the HQ root.

```bash
f="$(mktemp -d)/signed-out-cards.json"
entry='{"provider":"claude","account":"frog","label":"frog","reason":"signed out: sign-in revoked","fix":"hq capacity login claude --account frog"}'

# 1. Is it a signed-out entry? Prints true.
printf '%s' "$entry" | jq '.account != null and .fix == ("hq capacity login " + .provider + " --account " + .account)'

# 2. Should it raise? The file is empty, so this prints raise.
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
key="$(printf '%s' "$entry" | jq -r '.provider + ":" + .account')"
reason="$(printf '%s' "$entry" | jq -r .reason)"
[ -f "$f" ] || printf '{"schema":"conduct-signed-out-cards.v1","cards":{}}\n' > "$f"
jq -r --arg k "$key" --arg r "$reason" --arg now "$now" '
  .cards[$k] as $c
  | if $c == null then "raise"
    elif $c.state == "disabled" then "skip"
    elif $c.reason != $r then "raise"
    elif $now >= $c.suppress_until then "raise"
    else "skip" end' "$f"

# 3. Print the card instead of raising it.
printf '%s' "$entry" | jq -r '"Title: Sign back in: \(.provider) account \(.account)\nQuestion: Run: \(.fix)\nContext: Account \(.account) (\(.provider)) is signed out: \(.reason). Blocked: multi-provider-compute-router US-015, lane 01EXAMPLELANE."'

# 4. Record it with a 24 hour window. This is macOS date; on Linux use
#    date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ.
until="$(date -u -v+24H +%Y-%m-%dT%H:%M:%SZ)"
jq --arg k "$key" --arg r "$reason" --arg now "$now" --arg until "$until" \
   --argjson e "$entry" '
  .cards[$k] = {reason: $r, fix: $e.fix, card_id: "dry-run", raised_at: $now,
    suppress_until: $until, rereads: 0, state: "open",
    blocked: [{project: "multi-provider-compute-router", story: "US-015",
               lane: "01EXAMPLELANE", at: $now}]}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"

# 5. Run step 2 again. Same reason inside the window, so it prints skip.

# 6. Model the owner choosing "Disable this account" and move the window
#    into the past. Run step 2 again: it prints skip, because a disabled
#    entry never raises.
jq --arg k "$key" '.cards[$k].state = "disabled"
  | .cards[$k].disabled_at = "2026-10-13T11:00:00Z"
  | .cards[$k].suppress_until = "2000-01-01T00:00:00Z"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
```

Set `reason` to `signed out: missing profile scope` and step 2 prints `raise`
again. Delete the `claude:frog` key from the scratch file to model a cleared
sign-out; step 2 then prints `raise` for the next sign-out. A real run replaces
step 3 with the `exec-bus.sh raise` command above and writes the shared dedupe
file in `workspace/orchestrator/`.
