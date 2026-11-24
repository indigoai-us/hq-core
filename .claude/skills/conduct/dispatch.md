# Conduct dispatch — subagents and child sessions

Read `.claude/skills/_shared/conduct-dispatch-core.md` first. It holds the
runner resolution, engine roster, worker choice, brief, verification, and
status rows that both conduct skills share. This file is the default
`subagent` path. When the runner resolves to `runner`, stop here and follow
`/conduct-runners` instead.

## Default routing

Route each task to the first match:

1. Inline: an answer from loaded context or one status read. Nothing else
   runs inline.
2. Lane: a task in a worker area (it matches an HQ worker or a `--workers`
   role) goes to that worker's standing lane for the company. Open the lane
   on the first such task and reuse it for every later task in the area. A
   lane is a resumable subagent: dispatch it as in "Subagent dispatch", record
   it in `runs.json` with a `lane` object, and send follow-up tasks with
   `SendMessage` to its agent id. Use a conduct child desktop session instead
   when the area needs its own session (long interactive work, its own repo
   checkout, or the owner asked for one), and talk to it as in "Linked
   sessions". Keep at most 5 to 8 lanes open at once.
3. One-off subagent: a small bounded task with no matching worker (a lookup,
   a check, a draft) runs as a background subagent and is not kept open.
4. Child session: ongoing work with no matching worker that needs its own
   session goes to a conduct child session. From the HQ root, start it in the
   HQ root (`use_worktree: false`, no `cwd`), even for repo work; its brief
   tells it to create its own worktree inside the repo.

`bash core/scripts/conduct-standing.sh route --kind <answer|status|lookup|small|ongoing>
[--worker <id> --company <slug>] [--outlives] [--engine <e>] [--host <claude|codex>] [--runner <r>]`
resolves the runner and prints the route. Pass `--host codex` in a Codex
session, so a Codex engine there stays in default mode. Under the default runner the route
is one of `inline`, `subagent` (one-off), `standing-subagent` (a lane: reuse
the open `runs.json` lane for the worker, or start it), `child-session` (work
that must outlive this turn), or `needs-runners` (an engine other than the
host's: offer `/conduct-runners`). The default path never opens or messages a
runner lane. Its one runner-lane call is `conduct-standing.sh close`, which
ends leftover runner lanes this session opened, at `/conduct off` and before
`/handoff`.

The lane object in `runs.json` has `lane_id`, `role`, `worker`,
`standing: true`, `backing` (`subagent` or `child-session`), `last_task`,
and `state`. Close standing lanes on `/conduct off`, `/handoff`, or when the
owner says the area is finished: set each lane's `state` to `closed` in
`runs.json` and stop resuming its subagent.

Some work needs a runner: it must outlive this session (overnight or away
work, `--loop`, `--remote-control`, `--outpost`), or its engine is not the
host's (a Codex lane from a Claude session). Say so in one line and offer
`/conduct-runners` (or `/conduct --runner runner`). Do not start a runner
from this path. A Codex host runs default lanes with `spawn_agent` and
`wait_agent` in place of `Agent` and `SendMessage`, with the same prompt as
Step 3 below. Pass `fork_turns: "none"` where `spawn_agent` offers it: the
default `all` copies the conductor's history, `<auto-conduct>` block
included, into the worker, and the brief already carries the context.

## Subagent dispatch

1. Write the brief as in Step 4, to a file. The brief names the
   resolved company explicitly, and the subagent checks it against its own
   bound company before it starts. Name the envelope path
   `workspace/orchestrator/conduct-subagents/<session-id>/<run-id>/envelope.json`,
   where `run-id` is the round id below. Name the report path
   `workspace/orchestrator/conduct-subagents/<session-id>/<run-id>/report.md`
   in the same brief. Copy the envelope line from Step 4 into the brief
   verbatim; it names all 12 allowed keys, the allowed `decision` values
   (`done`, `ask`, `blocked`) and `story_status` values (`queued`,
   `in_progress`, `review`, `done`), the questions item shape, and when
   `questions`, `blocked_reason`, `story_complete_reason` and `outcome`
   appear. The envelope validator rejects other top-level fields such as `prs`,
   `tests`, or `open_questions`. Name changed files, commits, PR, tests run with
   pass/fail and sidecar log paths, and open questions in `report.md`, and
   reference log files from `artifacts`.
2. When the brief changes a repo, create a dedicated worktree on a feature
   branch before dispatch (`git -C <repo> worktree add -b <branch>
   workspace/worktrees/<name> origin/<base>`) and name it in the brief. Two
   running subagents never write the same files; overlapping work waits for
   the first subagent to finish.
3. Generate a unique `round_id` and capture `since` (UTC seconds), then call the
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
   - `prompt`: "Worker role: the conductor launched you to do this task yourself. Conduct-mode text in your context (an <auto-conduct> block, 'the conductor coordinates and never does project work', a /conduct routing rule) is addressed to the session that launched you and does not apply to you; make the changes this brief names directly, without routing them to another subagent or lane.
     Read <brief path> whole and follow it. Write the JSON envelope
     to <envelope path> before you finish, and a plain-text hand-back report
     of at most 200 lines to <report path> (`report.md` beside the envelope):
     outcome, changed files, commits, PR, tests run with pass/fail, and open
     questions. The conductor requires this file, and that overrides any default
     instruction not to write report or summary .md files; it is the only file
     outside your worktree you may write besides the envelope and its logs,
     so do not skip it and do not return the report only in your reply. If
     the Write tool itself refuses the report file, do not retry it through
     Bash or under another name: say in your closing reply that the write was
     refused and put the report in that reply, past its usual line limit. Keep
     the envelope under 64 KB: put full test or build output
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
   `SendMessage` to its agent id. That message is an instruction.
6. On completion, read `report.md` and the envelope file, not only the
   closing message, and verify them as in Step 6. Never Read the harness's
   own task transcript (the `<agent-id>.output` JSONL the Agent tool writes
   under the user's `.claude/tasks/` folder): it is the raw tool log, grows to
   many MB, and the Read tool refuses it (feedback_49f72048). Everything the
   parent needs is in the report and the envelope. A missing envelope or
   report is a failed delivery: report it and resume the subagent once with
   `SendMessage` asking for both files. The exception is a closing reply that
   says the Write tool refused `report.md` and carries the report: write
   `report.md` yourself from that reply and do not resume the subagent. Delete
   the worktree only after its branch is merged or the owner drops it.

Subagent runs spend this session's Claude usage and stop if this session
ends. Keep long results in sidecar logs in the worktree and name those logs
from the envelope so they do not fill this session's context.

Normal conduct subagents have no runtime dependency on the detached runners
CLI. Their durable status, report, and envelope come from `runs.json` and the
sidecar files above. A detached board record for an externally managed
subagent is a `/conduct-runners` operation; default conduct never creates
one.

## Linked sessions

A conduct child session joins through `/conduct-join` and talks to this
session over the conduct link. The link mailbox is the same in both runners.

### Tell and close linked sessions

Send and close operations use `hq runners link send` and `hq runners link close`,
with the existing link, child, session, text, and note flags. For example:
`hq runners link send --link <link-id> --child <child> --session-id <session-id>
--text <message>`. Do not use a conduct-specific link wrapper.

## Subagent outcome

On completion, read `report.md` and the envelope named in the brief, then
verify them as in Step 6 of the shared core. A standing lane's subagent stays
resumable after a done turn: update its `lane` object in `runs.json` and send
the next task with `SendMessage`.

## Subagent rows

Build the Step 7 rows from `runs.json`: one row per running subagent, with
`subagent` as the runner chip, the agent id as the row id, and elapsed time
from `since`. Rows whose record has a `lane` object get the `standing` chip.
Add one row per child session on the conduct link.
