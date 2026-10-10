# Shared lane dispatch protocol

`/conduct`, `/execute-task`, and `/run-project` create worker lanes through
`hq lanes`. The calling session remains the senior. This file is the shared
mapping; each skill supplies its own brief and verifies its own result.

| Former conduct operation | Lane-native operation |
|---|---|
| Assign a named worker and brief | `hq lanes create --worker W --brief-file F --senior session:<id> --json` |
| List and record worker state | `hq lanes list --json`, filtered to lanes launched by this senior |
| Stop or preserve a worker thread | `hq lanes stop <lane>` or `hq lanes interrupt <lane>` |
| Read pending questions and answers | `hq lanes questions list --json` and `hq lanes questions answer` |
| Send a worker instruction | `hq lanes message <lane> --text <instruction>` |
| Send or close a linked session | `hq lanes link send` or `hq lanes link close` with the same session flags |
| Wait for a lane change | `hq lanes wait --any <lane...> --for envelope --for question --for state --timeout <seconds> --json` |
| Read results | `hq lanes show <lane> --json` and the lane envelope |
| Run directory and lifecycle state | hq-cli lane registry and lane artifacts; callers do not read a private run directory when a CLI command exposes the data |

## 1. Why detached, and what it buys

`hq lanes create` registers and launches a worker lane asynchronously. The
senior session stays responsive, while hq-cli records the lane state, envelope,
questions, and result. Do not start a second runner beside hq-cli.

## 2. Resolve one engine per run, before you brief anything

Resolve the provider once from explicit user choice, saved session choice, or
the worker profile. For `/conduct --workers`, resolve provider, model, and
effort once and pass the same pins to each role lane. Ask once only if no
configured provider is available.

### The roster

| Provider | CLI value |
|---|---|
| Codex | `codex` |
| Claude | `claude` |
| Grok | `grok` |

## 3. The brief goes on disk; the command line carries a path

Write a complete brief to a new file before creating the lane. Include company,
project, story, worker, repo/worktree, acceptance criteria, tests, constraints,
and the output envelope path. Never inline a long task prompt in the CLI call.

## 4. Launch

Create the lane from the HQ root. Worker lanes use the caller as senior:

```bash
hq lanes create --company <company> --project <project> --story <story> \
  --worker <worker> --brief-file <brief> --senior session:<session-id> \
  --json
```

Pass every set session pin on every `/conduct` lane: `--provider` from
`conduct_engine`, `--model` from `conduct_child_model`, and `--effort` from
`conduct_child_effort`. An explicit flag overrides its matching session pin.
Repeating create for the same worker under the same
senior continues that worker's thread. When the lane is still live, use
`hq lanes message <lane> --text <instruction>`.

The detached lane launcher captures its owner PID and start time with
`bash core/scripts/hq-detach.sh --owner-pidfile "$RUN_DIR/owner.pid" -- ...`.
The reaper uses that record to keep lanes whose owning session is still alive.

## 5. Record, then wait in the background

The lane registry is the record. Parse the create JSON for `ok`, `lane_id`, and
the admission result. Admission or capacity refusal leaves the task queued for a
later tick. Claude parents arm `Monitor(hq lanes watch <lane>)` or a bounded
background `hq lanes wait`. Codex parents generate a unique
`round_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"` before every
dispatch, then capture
`since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"` immediately before the create, message,
resume, or question-answer call. After the call, start one watcher for that lane
and round with
`bash core/scripts/lanes-completion-watch.sh start --lane <lane-id> --provider
codex --session-id "$CODEX_SESSION_ID" --since "$since" --round-id "$round_id"`.
That starts a persistent `hq monitor` targeted to the parent session; it checks
`hq lanes show` before and after each bounded `hq lanes wait --any <lane> --for
envelope --for state --for question --timeout <seconds> --json` call. Receipt
and monitor files under `workspace/lanes-runs/<lane-id>/codex-completion/` key
by `since` and unique round ID. Different IDs keep same-second dispatches
separate; reusing an ID suppresses duplicate starts and events. The start
command rejects a mismatched owner. Each event includes its `since` value,
outcome, lane state, and current envelope reference or worker log path. If
monitor startup fails, report dispatch failure and do not say a notification
was scheduled. Codex sees the event on its next tool call or user message; it
cannot answer while idle. Arm one watcher per lane per round. Read
the wait JSON and do not use the exit code as the delivery verdict.

### Confirming the engine group — run this last, on every outcome

The lane registry and its state are authoritative; do not kill or recycle
process groups based on a missing envelope. If a lane is stuck, inspect
`hq lanes show <lane> --json` and use `hq lanes interrupt` when its session must
be preserved, or `hq lanes stop` when it must be ended.

## 6. Correcting a lane mid-flight

Use `hq lanes message <lane> --text <instruction>` or `--text-file <path>` for
worker lanes. The message is an instruction and can replace earlier scope. Use
`hq lanes link send` for linked sessions.

## 7. Reading the outcome

Read the envelope and artifact paths reported by the lane. Inspect the diff,
commit, and tests directly. For a PR, verify the remote head and all check runs
against that head. `decision: "done"` and a process exit code are claims to
verify, not delivery evidence.

## 8. Phase envelope and handoff shape

Loop lanes carry phase envelopes and handoffs. `/execute-task` and `/run-project`
own the run state; this schema is the shared shape. A loop lane is created with
`--loop` and still uses the caller as senior. Preserve each phase's story id,
worker id, acceptance criteria, and result path in its envelope.

### Phase envelope (`schema: "hq-phase-envelope/v1"`)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schema` | string `hq-phase-envelope/v1` | yes | Shape tag |
| `story_id` | string | yes | Project-qualified story id |
| `phase` | string | yes | Phase name |
| `worker_id` | string | yes | Worker assigned to this phase |
| `worktree` | absolute path | yes | Repo worktree for the phase |
| `incoming_handoff` | path or null | yes | Previous phase output, if any |
| `acceptance_criteria` | string array | yes | Checks the phase must satisfy |
| `deadline` | ISO-8601 UTC string | yes | Phase deadline |
| `fresh_call` | boolean | yes | Whether to start a new provider session |
| `project` | string | no | Project slug |
| `engine` | string | no | `claude`, `codex`, or `grok` |
| `result_path` | path | no | Where the phase writes its handoff |
| `story_title` | string | no | Story title |
| `story_description` | string | no | Story description |
| `constraints` | string array | no | Run-wide hard limits |
| `repo` | string | no | Resolved repo path |
| `branch` | string | no | Branch checked out in `worktree` |
| `reopen_note` | string | no | Why a verified story was reopened |
| `resumed_after_interrupt` | boolean | no | Whether this phase continues after a stop |
| `prior_handoff` | path | no | Partial output from the interrupted phase |

When a worktree lives under `repos/`, the `repos-worktree line` tells the
worker that shell or patch edits are required by the repo Write/Edit guard.
Retain the branch, reopen, interruption, and prior handoff fields when present.

### Phase handoff (`schema: "hq-phase-handoff/v1"`)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schema` | string `hq-phase-handoff/v1` | yes | Shape tag |
| `story_id`, `phase`, `worker_id` | string | yes | Copied from the envelope |
| `status` | `passed`, `failed`, or `blocked` | yes | Phase result |
| `summary` | string | yes | What the phase did |
| `files_changed` | string array | yes | Changed paths |
| `commits` | string array | yes | Commits made |
| `back_pressure` | object | yes | Test, lint, typecheck, and build state |
| `context_for_next` | string | yes | Information for the next phase |
| `engine` | string | no | Provider used |
| `notes` | string | no | Additional detail |

Acceptance evidence is optional but, when supplied, each entry names the
acceptance criterion index, a boolean result, and non-empty evidence. A passing
status alone does not prove that all acceptance criteria were met.
