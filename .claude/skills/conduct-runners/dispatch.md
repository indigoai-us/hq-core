# Conduct runners dispatch — detached worker lanes

Read `.claude/skills/_shared/conduct-dispatch-core.md` first. It holds the
runner resolution, engine roster, worker choice, brief, verification, and
status rows that both conduct skills share. This file is the advanced
`runner` path used by `/conduct-runners`: lanes run as detached `hq runners`
runners under hq-cli admission. Lanes use the shared mapping in
`.claude/skills/_shared/lane-dispatch-protocol.md` and the same lifecycle used
by `/execute-task` and `/run-project`.

## Runner rules

Under `runner` (which replaces the old `mixed` value):

- A task that matches an HQ worker or a `--workers` role goes to that
  worker's standing lane (see "Standing worker lanes"): opened on the first
  such task, reused for every later task for the same worker and company.
- Ongoing work with no matching worker, and every small bounded task with no
  matching worker (a lookup, a check, a draft), goes to a background
  subagent. `hq runners create --worker` needs a registered worker, so there is
  no standing lane without one.
- Nothing runs inline beyond an answer from loaded context or one status read.

When the owner asks for lanes only, a task that matches a worker uses that
worker's standing lane and any other task gets a one-shot lane. Background
subagents run through the host's in-session agent tool. Register each one
as a subagent-runner lane and report through `hq runners progress <lane-id>`;
SKILL.md, "Routing", has the exact command. The brief, envelope
path, and launch call are the ones in "Subagent dispatch" in
`.claude/skills/conduct/dispatch.md`.

Use a one-shot lane when any of these hold:

- The work must outlive this session: overnight or away work, lead lanes
  that resume on their own, `--loop`, `--remote-control`, or `--outpost`.
- The engine is not Claude, or the host has no `Agent` tool (Codex sessions).
- The owner asked for a lane for this task.

Use a subagent, even for a lanes-only request, when `hq runners create` returns
`ok:false` with `no_account_with_room` or any other admission or capacity
code. Report the switch in one line, for example
`lanes refused (no_account_with_room, next reset <next_reset>); running as a subagent`.
Still raise the signed-out owner cards from the refusal's `skipped[]`.

`bash core/scripts/conduct-standing.sh route --kind <answer|status|lookup|small|ongoing>
[--worker <id> --company <slug>] [--outlives] [--engine <e>] [--runner <r>]`
resolves the runner as above, applies these rules, and prints `inline`,
`subagent`, `lane-reuse` (with the lane id), or `lane-open` (with
`standing`).

Steps 2 and 4 come from the shared core.

## Standing worker lanes

Workers stay open. A standing lane is one
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
   brief with `hq runners message <lane> --text-file <brief>` and prints
   `"action":"reused"`. Otherwise it runs `hq runners create --company <company>
   --worker <worker> --keep-alive --senior session:<session-id>`, then
   `hq runners keep-alive <lane> --on --standing` so the lane waits for queued
   work after every done turn, records the lane in
   `workspace/sessions/<session-id>/conduct-standing-lanes.json`, and prints
   `"action":"opened"`. A repeated create for the same worker and senior
   continues that worker's prior thread.
3. `--company` is required. Every lane is bound to its company
   (`hq-background-jobs-require-bound-company`), and a standing lane is never
   reused across companies.
4. Exit 3 means `hq runners create` refused (capacity or admission). The create
   JSON is on stdout. Run the same brief as a subagent and report the switch
   in one line, as in "Runner rules".
5. Arm the watcher for the lane round as for any lane message or create
   (round id, `since`, `Monitor(hq runners watch <lane>)` or the Codex watcher).
6. Close on `/conduct off`, `/handoff`, or when the owner says the area is
   finished: `bash core/scripts/conduct-standing.sh close` turns keep-alive
   off with `hq runners keep-alive <lane> --off` and interrupts each lane with
   `hq runners interrupt`, so the lane stays resumable for a later session.
   `--dry-run` lists what it would close. Use `conduct-standing.sh forget
   --lane <id>` to drop one lane from the record after closing it by hand.

`hq runners doctor` and `hq runners keep-alive-audit` report keep-alive lanes
blocked by retired, superseded, or pending-question state; run them in
`/conduct status` when a standing lane looks stuck.

## How work leaves this session

1. Resolve the active company, project, story, and worker profile. A task in
   a worker area goes through "Standing worker lanes" above. For any other
   lane, reuse an existing lane under this senior when its repo and task fit.
   Check `hq runners list --json --senior session:<session-id>` first.
2. Write the complete task brief to a file. Include done criteria, company and
   repo paths, constraints, required tests, the JSON envelope path, and the
   envelope line from Step 4 of the shared core, copied verbatim. That line
   names all 12 allowed keys, the allowed values, the questions item shape,
   and when `questions`, `blocked_reason`, `story_complete_reason` and
   `outcome` appear.
3. Create a worker lane using the mapping below. Keep HQ root as the CLI cwd.
   ```bash
   hq runners create --company <company> --project <project> --story <story> \
     --worker <worker> --brief-file <brief> --senior session:<session-id> --json
   ```
   Add `--provider` from `conduct_engine`, `--model` from
   `conduct_child_model`, `--effort` from `conduct_child_effort`, and
   `--account` from `conduct_child_account` whenever those session pins are
   set, for every `/conduct` lane. A user flag overrides the matching session
   pin. When neither a `conduct_child_account` pin nor a user `--account` flag
   is set, pass `--account auto` so hq-cli picks the account with the most room
   from the shared pool. Add the placement flag (`--outpost <id>`, with the
   lane's `--company` for a company Outpost, `--placement auto`, or
   `--placement local`) chosen under
   `core/policies/hq-lane-outpost-choice.md`; never pick an Outpost silently.
   A repeated create for the same worker and senior continues its prior lane
   thread. If the lane is live, send follow-up work with
   `hq runners message <lane> --text <instruction>`.
4. Parse the JSON response. An admission or capacity refusal, including
   `no_account_with_room` from `--account auto`, moves the task to a subagent
   with the same brief (see "Runner rules"). Report the switch and the soonest reset
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
5. Immediately before every `hq runners create`, generate a unique `round_id`
   and capture the round baseline `since` in UTC seconds. After the create
   returns its lane id, arm one Codex watcher for that lane and round:
   ```bash
   round_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
   since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   hq runners create ...
   bash core/scripts/lanes-completion-watch.sh start --lane <lane-id> \
     --provider codex --session-id "$CODEX_SESSION_ID" \
     --since "$since" --round-id "$round_id"
   ```
   Claude parents arm `Monitor(hq runners watch <lane>)` or a bounded background
   `hq runners wait` before returning.
   This starts a persistent `hq monitor` targeted to
   `session:codex:$CODEX_SESSION_ID`. The monitor command checks `hq runners show`
   before waiting and after every bounded
   `hq runners wait --any <lane> --for envelope --for state --for question --timeout <seconds> --json` result. It
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

`hq runners create --account auto` and `hq capacity route --json` list every
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
from the JSON, the card's `card_id`, `raised_at`, `suppress_until`, the
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

Ask the owner in this session's own window with one picker, the only
place this question is asked:

```text
Title:    Sign back in: <provider> account <account>
Question: Run: <fix>
Options:  I ran it (I signed the account back in)
          Later (ask again in 24 hours)
          Disable this account (stop routing lanes to it)
Context:  Account <account> (<provider>) is signed out: <reason>.
          Blocked: <project> <story>, lane <lane-id>.
          Conduct never signs in for you; run the command yourself.
```

Set `card_id` to `signed-out:<provider>:<account>:<raised_at>`. A lane that
was refused stays queued under the existing handling; the card does not change
that. If the host has no picker, print the same title, command, and context in
this turn's status row and still write the dedupe entry.

### Answers

The answer is the option the owner picks, or the same words typed in this
session. Match it to the dedupe entry by the account named in the card.

- `Disable this account`: run `hq runners accounts disable <provider> <account>`,
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

`hq runners create ... --account auto --json` returns this entry:

```json
{
  "provider": "claude",
  "account": "acct-a",
  "label": "acct-a",
  "organization": "Example Org",
  "reason": "signed out: sign-in revoked",
  "fix": "hq capacity login claude --account acct-a"
}
```

The lane was for project `multi-provider-compute-router`, story `US-015`, lane
`01EXAMPLELANE`. The card reads:

```text
Title:    Sign back in: claude account acct-a
Question: Run: hq capacity login claude --account acct-a
Options:  I ran it | Later | Disable this account
Context:  Account acct-a (claude) is signed out: signed out: sign-in revoked.
          Blocked: multi-provider-compute-router US-015, lane 01EXAMPLELANE.
          Conduct never signs in for you; run the command yourself.
```

`workspace/orchestrator/signed-out-cards.json` after the raise:

```json
{
  "schema": "conduct-signed-out-cards.v1",
  "cards": {
    "claude:acct-a": {
      "reason": "signed out: sign-in revoked",
      "fix": "hq capacity login claude --account acct-a",
      "card_id": "signed-out:claude:acct-a:2026-10-13T10:15:00Z",
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

An hour later a lane for another project skips `claude:acct-a` with the same
reason. Conduct adds that project, story, and lane to `blocked[]` and raises
nothing.

## Step 3: Assign a pool slot

This step applies to lanes only; subagents take no pool slot. There is no
conduct pool. `hq runners create` is the admission operation and applies
hq-cli's provider, account, host, and lane capacity rules. If admission
returns `ok:false` with an admission or capacity code, run the task as a
subagent (see "Runner rules"), or leave it queued when it must outlive this session.
Do not invent a second machine-wide cap or start another lane around the
refusal. With `--account auto`, `no_account_with_room` means every account in
the pool is out of room. Report the soonest reset in one line. Do not choose
an account yourself.
Generate a unique
`round_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"` before each create,
then capture `since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"` immediately before the
call. This includes a repeated create that resumes a worker's existing lane. Pass both
values when arming the Codex watcher after the lane command returns.

## Step 5: Launch the lane, detached

Run `hq runners create` from the HQ root with `--senior session:<this session>`.
Read the returned JSON for `ok`, `lane_id`, and any admission code. The CLI
launches asynchronously; do not wait in this session for the worker to finish.
Arm the watcher immediately.

## Step 5b: Send a message to a lane that is already running

Generate a unique `round_id`, then capture `since="$(date -u
+%Y-%m-%dT%H:%M:%SZ)"` immediately before each `hq runners message`. After the
command returns, arm a new round watcher with `bash
core/scripts/lanes-completion-watch.sh start --lane <lane> --provider codex
--session-id "$CODEX_SESSION_ID" --since "$since" --round-id "$round_id"`. Use
`hq runners message <lane> --text <instruction>` (or `--text-file`) for a
worker lane. Use `hq runners link send` for an adopted session. Include the
project and story flags when changing attribution. A live worker's message is
an instruction and may supersede its original brief.

## Lane outcome

Before answering a lane question or resuming a lane, generate a unique
`round_id`, then capture a fresh `since` immediately before the
`hq runners questions answer` or `hq runners resume` call. Afterward, start a new
Codex watcher for that lane round with `--since "$since" --round-id
"$round_id"`.

For a lane, use `hq runners show <lane> --json` and the lane's envelope, then
verify as in Step 6 of the shared core. A lane's exit code never determines
whether its artifacts were delivered.

## Step 6R: Role lanes (`/conduct --workers`)

Generate a unique `round_id` before every role-lane dispatch, then capture
`since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"` immediately before each create,
message, resume, or `hq runners questions answer` call. After each call, start
one Codex completion watcher with that lane, `--since "$since"`, and
`--round-id "$round_id"`. This includes QA-failure returns and each CI-fix
round on a reused lane. Claude parents keep the `Monitor(hq runners watch ...)`
path.

`--workers <roles>` opens one standing lane for each requested role with
`conduct-standing.sh send --worker <profile>`, using the role mapping in
Step 2 of the shared core. Pin provider,
model, effort, and account once per session and pass those pins to each
`hq runners create`. With no account pin, pass `--account auto` to each one. Build each brief from the matching role template. The role
slot is one worker lane; create resumes that worker's previous lane thread when
possible. If it is still live, send the next instruction with `hq runners
message`.

For a QA lane, use `lanes-workers.sh needs-qa`: frontend and designer roles
need QA; otherwise UI file extensions trigger it. After a lane opens a PR, use
`lanes-workers.sh ci` to read `gh pr checks` output. The check loop waits for a
stable set, fails closed on unreadable checks, and reports no checks separately
from pass. Count CI fix rounds with `lanes-workers.sh ci-round`; after the
configured maximum, return the decision to the operator rather than looping.
When `needs-qa` returns `yes`, create a `qa-tester` lane from the QA role brief,
send it the PR URL, and wait for its envelope. Return QA failures to the owning
implementation lane with `hq runners message`; report the QA result with CI.

## Lane rows

Add these rows to the Step 7 rows from the shared core. List lanes launched
by this session with `hq runners list --json --senior session:<this session>`.
For each active row include the lane id, worker, state, `last_line`, PR,
pending inbox count, elapsed time, and exit status when present. Mark
standing lanes from `conduct-standing.sh list` with a `standing` chip; an idle
standing lane waiting for work still gets a row. Use a named reviewing lane
for `review` state.

## Testing capacity distribution locally

To check that unpinned lanes spread across accounts, clear any
`conduct_child_account` pin and create two lanes with no `--account` flag, so
each create passes `--account auto`. Then run:

```bash
hq capacity route --json
hq runners show <lane-1> --json
hq runners show <lane-2> --json
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
entry='{"provider":"claude","account":"acct-a","label":"acct-a","reason":"signed out: sign-in revoked","fix":"hq capacity login claude --account acct-a"}'

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
again. Delete the `claude:acct-a` key from the scratch file to model a cleared
sign-out; step 2 then prints `raise` for the next sign-out. A real run replaces
step 3 with the owner picker above and writes the shared dedupe
file in `workspace/orchestrator/`.
