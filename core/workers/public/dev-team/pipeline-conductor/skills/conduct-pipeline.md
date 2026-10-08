# conduct-pipeline

Run a project's stories as a pipeline of pooled worker lanes. All state lives
in one state dir (`--state`), so a run survives compaction and restarts.

Loop: `core/scripts/pipeline-driver.sh` (deterministic, no engine calls,
launched detached by the parent; never run it in the background of a lane).
Helper: `core/scripts/pipeline-conductor.sh` (run with `--help` for usage).
Shapes: `.claude/skills/_shared/lane-dispatch-protocol.md` §8.

## Inputs

- `prd.json` path, state dir, target worktree or repo path, and whether the
  repo is shared with other stories in flight.
- Optional `{state}/constraints.txt`: run-wide hard limits, one per line.
  `route` copies them into every envelope and the lane quotes them in the
  phase prompt.

## Classification and preflight checks

A story's worker sequence is its full phase sequence, in order. `classify`
takes it from the run's overlay (`{state}/overlay.json`), else the story's
`worker_preference`, else the keyword fallback (architect, the matched
implementers, qa-tester), and records the source in `stories/<id>.json` as
`classified_by` (`overlay`, `worker_preference` or `keywords`). The overlay
keeps the prd unedited:

```bash
pipeline-conductor.sh classify --prd P --state S --overlay <preflight-plan.json>   # import every worker_sequence
pipeline-conductor.sh overlay set --state S --story ID --sequence a,b,c
pipeline-conductor.sh overlay show --state S
```

`classify --prd P --state S --table <table.tsv>` without `--story` checks every
story that is not passing or skipped and writes nothing. It prints `OK`, `WARN`
and `ERROR` lines and exits 1 on any error:

- a worker id with no `worker.yaml` under the worker roots (the message names
  the roots and the nearest known ids);
- a story that declares code files (anything but `docs/`, markdown, text or
  yaml) whose sequence starts with a verifier or reader. The test reads
  `worker.role`, else `worker.type`, from `worker.yaml`: review, test, qa,
  architect or read make a verifier or reader; with no role set, an id that
  names one counts too. The fix is to prepend an implementer (`overlay set`)
  or mark the story `"docs_only": true`;
- a sequence worker with no row in the confirmed worker table (every missing
  worker is listed with its stories).

It warns on a one-worker sequence (architect and qa phases will not run), on a
`model_hint` (a table pin wins and the hint is reported as "hint ignored, table
pins <model>"; a bare alias such as `opus` is never used), and when a story's
acceptance criteria or files name a later story's id or a file only a later
story declares while its `dependsOn` lacks that story (the warning prints the
`dependsOn` line to use). `route` refuses a phase whose worker has no table row
(`NO_LANE`, exit 12) and the driver exits 27.

Skip list: `skip --state S --story ID [--note "why"] [--force] --prd P` leaves a
story out of the run (`{state}/skips.json`): it is not selected, routed, gated
or counted, and `FINAL:` lists it with its note. A story others depend on
prints `SKIP_STRANDS` with the dependents it would strand and needs `--force`.
`unskip --state S --story ID` reverses it.

## Driver passes

The driver repeats one pass every `--interval` seconds (default 15):

1. A `queued` or `held` story that still has a handoff for its current phase
   (the phase failed and is being retried) has that handoff moved aside to
   `handoffs/<id>-<phase>.failed.<n>.json`. When a phase has returned status
   `failed` `--max-phase-fails` times (default 2), the driver stops with exit
   21; the reason names the status and the number of attempts.
2. For each `in_flight` story whose current phase's handoff is at its
   `result_path`, `accept --story ID --handoff F`. It prints `NEXT <phase>`,
   `RECHECK`, `PHASE_FAILED` (exit 1; the phase goes back to `queued` for one
   more route), or `PHASE_BLOCKED <id> <phase> <decision>` (exit 10; see
   "Blocked phases"). The loop lane already ran `pipeline-envelope.sh normalize` and
   `validate --kind handoff` on the engine's reply, and writes a `failed`
   handoff when the reply was not valid, so the file is always a §8 handoff.
3. For each `awaiting_recheck` story, `recheck` (below).
4. Steps 1-3 repeat until nothing changes, then
   `tick --prd P --state S --worktree REPO=DIR [--worktree REPO=DIR ...] [--story-branches]`
   (the bare `--worktree DIR` form serves a single-repo prd):
   - Re-routes every `queued` story (a phase that just advanced, or one the
     pool refused last time).
   - Starts new stories from `next` while fewer than `PC_MAX_STORIES`
     (default 3) are active. In the default branch mode stories of a repo
     share one feature branch, so `PC_MAX_STORIES` is lowered to the number of
     worktrees in play (printed once as `MAX_STORIES <n> ...`) and a story
     whose repo branch already has a story in flight waits. `next` returns stories whose `passes` is not true
     and whose every `dependsOn` story passes (or was verified in this run),
     lowest `priority` first. It returns nothing while a regression gate
     failure is unresolved.
   - `classify` resolves each story's repo: story `repoPath`, then (when the
     prd lists several repos in `metadata.repos[]`, canonical, or the alias
     `metadata.repoPaths[]`) the repo that owns the story's first declared
     file, then `metadata.repoPath`. `route` sends every phase to the worktree
     mapped to that repo. A story whose repo has no worktree is held
     `blocked_needs_owner` (`BLOCKED_OWNER <id> <phase> no_worktree <decision>`).
   - Before launch the parent runs `worktree --repo R --shared --prd P` once per
     repo: one worktree on the run's feature branch (`metadata.branchName`,
     else `feature/<project>`). With `--story-branches`, `route` cuts one
     worktree per story when it first routes, stacked on the branch of the
     last verified story it depends on in the same repo; a missing dependency
     branch holds the story. Every cut starts from `origin/<baseBranch>` after
     a fetch, else local `<baseBranch>`, never HEAD, and prints
     `CUT <branch> from <ref> <sha>`. All git calls use `git -C`; a repo inside
     the HQ root (other than under `repos/`) is refused.
5. `route` checks the previous phase's handoff with `pipeline-envelope.sh
   validate` and requires `status: passed`, builds and validates the envelope
   (literal `acceptanceCriteria`, story title and description, constraints,
   worktree, deadline, `result_path`), and calls `conduct-pool.sh assign
   --worker-id <worker> --envelope <file>`. Pool exit 3 or 4 prints `RETRY`;
   the story stays `queued` for the next tick. Only an `enqueue` answer (a
   live loop lane took the envelope) routes the phase. Any other answer
   (`spawn`, `resume`) means the worker's loop lane is gone: route releases the
   claim with `conduct-pool.sh cancel`, leaves the story `queued`, prints
   `LANE_DOWN <id> <phase> <worker> ...`, exits 11, and the tick stops.

The driver exits, writing `{state}/driver/exit` as `<code> <reason>`:

| Code | When |
|---|---|
| 0 | no story is queued, in flight, held, blocked or awaiting recheck, and `next` is empty; `report final` has run (parked and accepted-partial stories count as finished) |
| 2 | usage error |
| 20 | `RUN_GATE`: run the regression gate in the `regression-gate` pool slot as /run-project Step 3c describes, then record `gate result pass\|fail --note ...` |
| 21 | a decision is needed: a story is `HELD` for approval; a story is `blocked_needs_owner` and nothing else can move; the gate is `GATE_FAILED`; or a phase returned `failed` `--max-phase-fails` times (`failcap` then holds the story as `blocked_needs_owner` and writes `decisions/<id>-blocked-<phase>.md` with each failed handoff's text) |
| 22 | an in-flight phase passed its envelope `deadline` with no handoff |
| 23 | the helper printed a line the driver does not know, or a call failed |
| 24 | another driver already runs against this state dir |
| 25 | stall: a phase has been in flight longer than `--stall-window` (default 600 seconds), no handoff landed, and `conduct-pool.sh list` shows every started lane `waiting` with `queue_depth` 0 |
| 26 | lane down: routing a phase got a pool answer other than an enqueue into a live loop lane. The reason names the lane; the story stays `queued` and the claim is released. Relaunch that worker's loop lane, then restart the driver |
| 27 | no lane: a phase's worker has no row in the confirmed table passed with `--table`. The story stays `queued`. Add the row, launch that lane, restart the driver |
| 130, 143 | interrupted or terminated |

While the gate is `failed`, `next` starts no new story; stories already in
flight may finish. A failed gate recorded with `--story ID` sets the gate to
`reopened` instead, which does not stop routing (see Reopen below). Every decision is read from the state dir, so a restarted
driver resumes where the last one stopped: `accept` only takes a handoff for a
story that is `in_flight` on that phase, so a handoff is never accepted twice
and a finished phase is not routed again.

Phases of different stories run at the same time whenever their worker lanes
are free. Nothing here spawns a child agent: no Task tool, `claude -p`,
`codex exec`, or `grok -p`.

## Acceptance re-check

A worker's `status: passed` is not enough. After the last phase, `recheck`
re-reads the story's literal `acceptanceCriteria` from prd.json and requires,
across the story's handoffs, one `ac_evidence` entry per criterion with
`met: true` and non-empty `evidence`.

Optional handoff field, in addition to the §8 handoff shape:

| Field | Type | Meaning |
|---|---|---|
| `ac_evidence` | array of `{index, met, evidence, criterion?}` | `index` is the 0-based position in `acceptanceCriteria`; `evidence` names the test, command output, or file that shows it; `criterion`, when present, must equal the literal text or the entry is ignored |

Outcomes:

- All met: `VERIFIED`, one report line, the gate cadence ticks.
- Any unmet, first time: `ROUTED_BACK` to the last phase with
  `fresh_call: true` (reroutes = 1). No report line.
- Any unmet, second time: `FAILED`, story state `failed_report`, one report
  line naming the unmet indexes.

The conductor never writes `passes` into prd.json.

## Decision items

If the phase's worker.yaml has `approval_required: true` or a non-empty
`verification.human_checkpoints`, `route` writes
`decisions/<story>-<worker>.md`, holds the story, exits 10, and writes no
envelope. Most dev-team workers carry `approval_required: true`, so the parent
usually pre-approves a worker for the whole run:

```bash
pipeline-conductor.sh release --state S --worker backend-dev
pipeline-conductor.sh release --state S --story US-004 --worker qa-tester
```

Release marks the decision `approved` and returns held stories to `queued`.

A story with `approval: "explicit"` (canonical; alias `needsApproval: true`),
or one the release detector flags (declared files or acceptance criteria that
mention deploy, release, production, or merging to the base branch;
`RELEASE_PATTERNS` in the script), is held `awaiting_go` before its first
implementing phase regardless of `approval_required`, with
`decisions/<story>-go.md`. `release` does not apply to it; only
`go --state S --story ID` does. `resolve` and `park` work on it. The driver
lists `awaiting_go` stories on its `TICK` lines and in `report.md` `FINAL:`.

## Blocked phases

A handoff with status `blocked` means a rerun cannot help (for example, the
criteria need a person or data the run may not touch). `accept` does not
re-queue it. It holds the story as `blocked_needs_owner`, keeps the handoff at
`handoffs/<id>-<phase>.json`, and writes one decision item,
`decisions/<story>-blocked-<phase>.md`, with the story id, phase, lane, the
attempt count, and the worker's own `summary` and `notes`. A blocked story
takes no `PC_MAX_STORIES` slot; the driver keeps routing every story that does
not depend on it and exits 21 only when nothing else can move.

On that exit the parent reads the decision item, asks the owner once with the
worker's blocker text, runs the matching command, and relaunches the driver.
Nothing below runs without the owner's answer:

```bash
pipeline-conductor.sh resolve --state S --story ID --as accepted-partial --note "owner's reason" [--prd P]
pipeline-conductor.sh resolve --state S --story ID --as retry [--note "owner's answer"]
pipeline-conductor.sh park    --state S --story ID [--note "why"] [--prd P]
pipeline-conductor.sh unpark  --state S --story ID [--prd P]
```

- `accepted-partial`: state `accepted_partial`, a terminal state distinct
  from `verified`. It counts as done for `dependsOn`. The note and the unmet
  acceptance criteria (from every handoff's `ac_evidence`) are stored in the
  story file and shown in its report line and the `FINAL:` line. `passes` is
  never set for it, and the report says so.
- `retry`: archives the blocked handoff, returns the story to `queued`, and
  the next route is a fresh call whose envelope `constraints` carry the
  owner's note.
- `park`: state `parked`. Every story that depends on it, directly or through
  other stories, is held as `parked_dependency`; the rest keep routing. The
  `FINAL:` line lists each parked story, its note, and what it holds. `park`
  first prints `PARK_CLOSURE <id> <n>: <ids>`; more than `PC_PARK_CONFIRM`
  (default 5) dependents needs `--force`. `unpark` restores the earlier state,
  releases the dependents and prints `UNPARK_RELEASES <id> <n>: <ids>`. Both
  append a line to `{state}/decisions.log`, as `skip` and `unskip` do.

Each command exits 1 with a message for a story in a state it does not apply
to, and prints `ALREADY ...` with exit 0 when repeated. A state dir written by
the previous version (a `queued` story whose newest archived handoff says
`blocked`) is read as `blocked_needs_owner`, so these commands work on it as is.

## Reopen

```bash
pipeline-conductor.sh reopen --state S --story ID --note "why" [--from-phase PHASE] [--prd P]
pipeline-conductor.sh gate result fail --state S --story ID --note "what the gate found" [--from-phase PHASE] [--prd P]
```

- `reopen` applies to a `verified` or `accepted_partial` story. It returns the
  story to `queued` at `--from-phase` (default: the first phase whose worker
  is not a reviewer or tester), refusing when an earlier phase has no passed
  handoff. The handoffs of that phase and later ones move to
  `handoffs/<id>-<phase>.reopened.<n>.json` and stay as history. The reroute
  and failed-attempt counts start over. The next envelope of that phase is a
  fresh call carrying `reopen_note` and a constraint line with the note. If
  the prd has `passes: true` for the story, reopen sets it to false and
  prints `PASSES_CLEARED`. The story's earlier report line is dropped.
- Dependents are never reopened. Stories that depend on it, directly or not,
  and are verified at the time are stored in the reopen record; the `FINAL:`
  line lists them as "verified before ID was reopened".
- `gate result fail --story ID` runs the same reopen, then sets the gate to
  `reopened` with the story in its list. `tick` routes reopened stories before
  other queued ones. When every story in the list verifies again, the gate is
  `due` (`RUN_GATE`). If the reopen is refused, the gate is not recorded.
  Without `--story`, `gate result fail` behaves as before.
- Refuses other states (exit 1); repeating it on a story still queued from a
  reopen prints `ALREADY` with exit 0.

## Back-pressure hint

When a story's `files` include a path containing `store`, `schema`,
`migration` or `db/`, every envelope of that story gets one constraint asking
the worker to run the repo's schema-contract tests as back-pressure, if
present.

## Report file

`{state}/report.md`, read by the parent:

- `report story --story ID` adds one line per finished story (verified or
  failed); repeated calls do not duplicate it. `recheck` writes it itself.
- `report final` writes one `FINAL:` summary line (verified, failed, partial,
  blocked, parked, held, unfinished, gate state, then the partial, parked and
  blocked stories by id), replacing any earlier one.
- No line per phase.

## Hard rules

- No child agents. No `passes` writes. No per-phase reporting.
- Every git command uses `git -C <path>`.
- One project and one tenant per state dir; run the pool-lane ownership check
  before reusing a lane.
- Do not wait on a human; write a decision item and let the driver stop for
  the parent.
- Never start a background loop inside a lane; the driver is the only loop.

## Owner retry

`resolve --as retry` re-reads the story from prd.json and re-classifies its
phases, replacing the cached list in `stories/<id>.json`, so a corrected
`worker_preference` takes effect. The story resumes at the first phase with no
passed handoff, and the failed-attempt count starts over (earlier failed
handoffs stay archived). It applies to a story held as `blocked_needs_owner`,
whether a handoff said `blocked` or a phase hit `--max-phase-fails`.
