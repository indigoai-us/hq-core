# Workflow Gates Spec

Human-in-the-loop pauses for long-running orchestrations. A **gate** is a
question written to disk by a paused workflow run; writing a matching answer
file resumes that run in place. The protocol is plain files, so it is
runner-agnostic: any orchestrator (the core workflow runner
`core/scripts/workflow-runner.mjs`, an agency worker, a bespoke script) can
open gates, and any session —
not just the one that launched the run — can answer them.

Design goals, in order:

1. **Pause in place.** The asking process stays alive and resumes from the
   exact point it paused. Nothing exits, so nothing re-runs.
2. **Answer from anywhere.** The pending file is self-contained (question,
   options, context, recommended choice, answer command), so a cold session
   can answer it without the launcher's context.
3. **Never ask twice.** Answers are durable. A crashed-and-relaunched run
   finds them and passes each already-answered gate instantly.

## File layout

```
workspace/gates/
  pending/<gate-id>.json     open questions (one file per gate)
  answered/<gate-id>.json    durable answers (survive the run that asked)
```

The gates root defaults to `workspace/gates/` under the HQ root and can be
relocated with `HQ_WORKFLOW_GATES_DIR` (legacy `CODEX_WORKFLOW_GATES_DIR` is
honored; tests use these for hermeticity).

Gate ids are slugged filenames: lowercase `[a-z0-9._-]`, no leading/trailing
separators. Orchestrators must slug caller-supplied ids before writing.
Because answers are keyed by id alone, ids must be scoped by the asking
pipeline (e.g. `myproject-approach`, not `approach`) so unrelated runs never
collide with — or silently reuse — each other's answers.

## Pending gate schema

Written atomically (tmp + rename) by the paused orchestrator:

```json
{
  "id": "myproject-approach",
  "question": "Which approach should the build take?",
  "options": [
    { "label": "option-a", "description": "one-line tradeoff" },
    { "label": "option-b", "description": "one-line tradeoff" }
  ],
  "context": "1-3 sentences a cold reader needs to decide.",
  "recommended": "option-a",
  "status": "pending",
  "created_at": "<ISO8601>",
  "run_id": "<orchestrator run id>",
  "run_dir": "<orchestrator run dir, for log spelunking>",
  "script": "<workflow script path or name>",
  "answer_path": "<abs path of the answered file the run polls>",
  "answer_hint": "bash core/scripts/workflow-gate.sh answer myproject-approach \"<choice|N>\""
}
```

`options`, `context`, `recommended`, `run_dir`, `script`, and `answer_hint`
are optional; everything else is required. `options` may be empty for
free-text questions.

## Answered gate schema

Written atomically by the answering party (the CLI does this):

```json
{
  "id": "myproject-approach",
  "choice": "option-a",
  "notes": "optional free text",
  "answered_by": "optional name",
  "answered_at": "<ISO8601>"
}
```

## Lifecycle

1. **Open** — the orchestrator hits a human decision, writes
   `pending/<id>.json`, emits a `GATE OPEN` signal line on stdout, and polls
   for `answered/<id>.json`. While gated it must run no agents and hold no
   concurrency slots.
2. **Answer** — any session runs
   `bash core/scripts/workflow-gate.sh answer <id> <choice|N>`. The CLI
   validates the choice against the gate's options (1-based numeric shorthand
   maps to the Nth label; `--freeform` records an off-menu choice; `--force`
   pre-answers an unopened gate or overwrites an existing answer), writes the
   answered file atomically, and removes the pending file.
3. **Resume** — the poll sees the answer, the orchestrator emits
   `GATE ANSWERED`, and the run continues from the pause point with the
   answer object in hand.
4. **Cached** — if `answered/<id>.json` already exists when a gate opens, the
   orchestrator must return it immediately (emit `GATE CACHED`) without
   writing a pending file or waiting. This is the crash-recovery contract: a
   re-launched run re-runs its agents but sails through every decision a
   human already made.

Poll-side robustness: a garbage or partially-written answered file is treated
as "not answered yet" — keep polling and pick up the next valid write.

## Answering CLI

`core/scripts/workflow-gate.sh`:

| Command | Behavior |
|---|---|
| `list` | One line per pending gate: id, age, question, numbered options |
| `show <id>` | Print the pending gate JSON (falls back to the answered file) |
| `answer <id> <choice\|N> [--notes "..."] [--by name] [--force] [--freeform]` | Validate and write the answer, remove the pending file |
| `wait-pending [--timeout secs]` | Block until any gate is pending (exit 0) or timeout (exit 1) — the un-scoped wake condition |
| `watch-run <run-dir> [--timeout secs]` | Block until a gate **belonging to that run** opens (exit 0, prints its id), the run finishes (exit 3), or timeout (exit 1) — see [Run-scoped watching](#run-scoped-watching) |
| `clear <id>` | Remove both the pending and answered files |

## Session integration

- **Launching session**: launch the orchestrator detached with an explicit
  `--run-dir`, then loop on `watch-run "$RUN_DIR"` (see below) — it wakes only
  for this run's gates and reports when the run is done. Surface each gate to
  the human with the runtime's structured picker (one question at a time, per
  `decision-queue-one-at-a-time`), answer via the CLI, and let the run
  continue. An off-menu human answer is recorded faithfully with `--freeform`
  plus `--notes`, never squeezed into the nearest offered option.
- **Any later session**: `/startwork` surfaces pending gates at session start
  so a returning human can answer without hunting for them.
- **Away from keyboard**: DM the owner (`hq dm`) with the gate id and answer
  command rather than letting a question sit silently.

## Hygiene

Answered files are the memory that prevents re-asking — keep them for the
life of the project that asked, then remove them with `clear` (or by
retiring the ids) once the pipeline is done. A stale answer under a reused
id will short-circuit a future gate silently; scoped ids (above) are the
guard.


## Run-scoped watching

A session that launches a workflow watches gates for **that run**, not for
whatever happens to be pending globally. Every gate payload carries the
`run_dir` the runner was launched with, and the launching session is the one
that chose that `--run-dir`, so the binding needs no id parsing, no env
coupling, and has no startup race:

```bash
bash core/scripts/workflow-gate.sh watch-run "$RUN_DIR" --timeout 900
#   exit 0  -> prints the id of a gate belonging to this run
#   exit 3  -> this run finished (its journal.jsonl carries run-done)
#   exit 1  -> timeout elapsed, run still live
```

`exit 3` is what lets a watch loop terminate on its own instead of hanging
after the last gate. `wait-pending` remains the un-scoped variant for an
operator triaging every pending gate on the box.

Launch long runs **detached** (`nohup ... < /dev/null & disown`). The runner
dies with its parent process, and agent work is not resumable — only human
answers are — so a session restart during an attached run discards every
completed stage.
