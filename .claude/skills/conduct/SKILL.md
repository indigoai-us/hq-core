---
name: conduct
description: Put the session into orchestrator mode — every task is assigned to a long-lived HQ worker from a capped session pool and run as a detached workflow-runner lane on a user-chosen engine (Codex, Grok, or Claude), so the parent session stays free to accept and route new messages. Use when the user says "/conduct", "run everything in the background", "keep the session free", "orchestrate through workers", or names an engine for delegated work.
allowed-tools: Bash, Bash(bash core/scripts/conduct-pool.sh:*), Bash(bash core/scripts/conduct-inbox.sh:*), Bash(bash core/scripts/hq-session.sh:*), Bash(bash core/scripts/resolve-company.sh:*), Bash(node core/scripts/workflow-runner.mjs:*), Read, Grep, Glob, AskUserQuestion
argument-hint: "[engine] [task description] | status | off"
---

# Conduct — Orchestrate the Session Through Background Lanes

The parent session is the conductor. It never does the work itself: it writes
briefs, launches lanes, relays results, and stays responsive.

**Live children: typical ≤ 8, worst case `CONDUCT_POOL_CAP` (default 8).**
Every task is assigned to a worker in the session pool, so fifty tasks still map
onto at most eight lanes. Independent tasks share the pool; they do not each open
a new one. See `core/policies/subagent-fanout-budget.md`.

## How work leaves this session

A task becomes one **detached lane**: a `core/scripts/workflow-runner.mjs`
process running a single `agent()` call against a headless coding-agent CLI. That
is the same runner `/orchestrate` drives for its pipeline stages, so a lane gets
the same hardening for free — unattended-run flags, stdin closed, HQ-root
anchoring so project hooks load, per-agent logs, and a soft timeout that warns
instead of killing.

Two properties matter more than the rest:

- **Lanes are OS processes, not in-session subagents.** Nothing here uses the
  `Agent` tool. A lane keeps running when this session compacts, restarts, or
  ends, and a host without in-session subagents can still run `/conduct`.
- **`setsid` is mandatory, not decorative.** A child left inside the session's
  process tree is swept at the turn boundary, minutes after the turn that
  launched it — which reads as an unexplained silent failure. `setsid` puts the
  lane in its own session where the sweep cannot reach it.

## Engine roster

| Choice | `engine` | Best for |
|---|---|---|
| `codex` (default) | `codex` | implementation, landing work, CI babysitting, fixes |
| `grok` | `grok` | fast implementation, a cheap second opinion |
| `claude` | `claude` | review, design, judgment-heavy work |

One difference that is not about quality: all three can be **corrected while
they run** (Step 5b), but only codex and claude take a message quietly. A grok
lane has to be interrupted — the message arrives as a denied tool call — which
costs it the step it was about to take. For work you expect to steer often, that
is a reason to prefer codex.

Each `agent()` call also names a `tier`: `exec` for execution (the throughput
model) or `plan` for analysis, review, and design (the flagship model). The tier
is required — the model choice is never implicit.

Before committing a brief to an engine, confirm it can actually run:

```bash
command -v codex grok claude
```

Configuration is not availability. An engine whose CLI resolves can still refuse
on a quota or balance error, and a refusal costs the same sixty seconds whether
it interrupts a throwaway probe or a fully briefed lane. If every engine is
unavailable, that is a blocker to hand back to the user immediately — naming
which engines were tried and what each returned — not something to retry around.

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
- First word is not a roster choice and no `conduct_engine` is set → ask ONE
  `AskUserQuestion` (options: the engines whose CLI is actually installed, codex
  recommended), then persist the answer.
- No task text → confirm the mode and wait.

## Step 2: Choose the worker (per task, every turn while the mode is set)

1. Resolve the active company with `bash core/scripts/resolve-company.sh`. One
   company per brief — never mix scopes.
2. Read `core/workers/registry.yaml`. It is auto-generated and already spans all
   three worker trees — `core/workers/`, `personal/workers/`, and
   `companies/<co>/workers/` — so there is only one file to read. Each entry
   carries `id`, `path`, `type`, `status`, `description`, `visibility`, `team`
   and `company`.

   Consider an entry only when both hold:

   - `status` is `active`; and
   - `company` is empty — a core or personal worker, available to every
     tenant — **or** exactly the active company slug.

   An entry naming a *different* company is out of scope. Do not fall back to it
   because it looks like a better match; a cross-company worker is a tenancy
   breach, not a near miss.

   Match the task against `id`, `type` and `description`.
3. No match → use a single general-purpose slot called `unmatched`. Do not search
   a catalog and do not create a worker.

The worker id is the pool's identity for this line of work. The same kind of task
returns to the same worker, which is what keeps the lane count flat.

### Load the worker's definition

A registry entry is an index card, not the worker. Once matched, read
`{path}/worker.yaml` — `path` comes from the registry entry and is relative to
the HQ root.

```bash
cat "{path}/worker.yaml"
```

Read it **whole**. Do not cap the read: the longest shipped definitions run past
220 lines, and what sits at the end is the part that matters most here —
`## Before You Finalize` checklists and the approval requirements below. A capped
read silently drops exactly the standing instructions this step exists to carry.

This is what makes the choice mean anything. Without it the worker id is only a
pool slot label, and every lane is identical no matter which worker was picked.
Take from it:

| Field | Use |
|---|---|
| `worker.name`, `worker.description` | who the lane is; opens the brief |
| `instructions` | standing instructions — fold in verbatim |
| `skills[].file` | the worker's actual procedures. Pass the **paths**, relative to `{path}`; the lane reads them itself |
| `context.base` | what the lane should read before starting — **resolve first**, see below |
| `knowledge` | knowledge files to load |
| `verification` | done criteria, and the approval rules below |
| `execution.max_runtime` | the lane's `timeoutSecs` (Step 5) |

`skills[].file` is reliable: every entry resolves against the worker's own
directory. `context.base` is not. Those paths are not uniformly rooted — some are
relative to the HQ root, some to `core/` — and a good many are simply stale. Of
the 175 distinct entries shipped today, 109 resolve from the HQ root, 17 only
under `core/`, and 49 point at nothing at all. Passing them through verbatim
hands the lane locations that do not exist.

So resolve each entry and pass only what survives:

```bash
for p in {context.base entries}; do
  for candidate in "$p" "core/$p" "{path}/$p"; do
    [ -e "$candidate" ] && { printf '%s\n' "$candidate"; break; }
  done
done
```

Drop an entry that resolves nowhere rather than passing it on. A brief that
points a lane at a missing path costs it a failed read and leaves it guessing
whether the gap matters.

Two fields are deliberately **not** applied. `execution.model` and
`codex_model` / `codex_flags` name models for delivery paths this skill does not
use — the engine is the operator's session-wide choice, and the tier follows the
task. Read them as a hint about how heavy the worker expects to be, nothing more.

**`verification.approval_required: true` and `verification.human_checkpoints` are
binding.** A worker that declares `before_merge_production` must not have its
lane merge to production. Carry every such checkpoint into the brief as an
explicit stop-and-report, and honour it in the parent: the lane prepares, the
parent asks the user once, and only then does the worker proceed. A worker that
asked for a human gate and did not get one is a defect, not a shortcut.

## Step 3: Assign a pool slot

```bash
bash core/scripts/conduct-pool.sh assign --worker-id "conduct:{worker}" --task "{short label}"
```

**The `conduct:` prefix is load-bearing.** A `/conduct` lane and an
`/execute-task` phase lane are not interchangeable even when they name the same
worker: `/conduct` stores a workflow-runner run directory as the `subagent_id`
and `/execute-task` stores a `Task` / `spawn_agent` handle, so a lane claimed by
one and resumed by the other would hand its id to the wrong adapter. They also
answer to different ownership rules — `/execute-task` lanes carry the
`owner.json` stamp from `.claude/skills/_shared/pool-lane-protocol.md`. Keeping
the namespaces apart means a session can use both without either reading the
other's state. Phase lanes use the bare id, story coordinators use `story:`, and
`/conduct` uses `conduct:`.

Read the JSON it prints and honour it:

- `{"action":"spawn",...}` → launch a new lane (Step 4).
- `{"action":"resume","subagent_id":"{run id}",...}` → that worker already has a
  lane history. Reuse it: launch into the SAME run directory and give the brief
  the previous lane's result file so the worker picks up its own thread instead
  of starting cold.
- `{"action":"spawn","recycled":"{other}",...}` → the pool was full, so the
  least-recently-used idle worker was retired to make room. Mention the retired
  worker when you report back; a silently dropped worker is a defect.
- **Exit 3** → the pool is at cap and every slot is running. Do not launch.
  Tell the user which workers are live and offer to wait. Do **not** reach for
  `recycle`: it frees the pool entry and cannot stop the sub-agent, so it now
  refuses a running lane with exit 5. Retiring one is only correct once that
  lane has reported and been marked `idle`, or the user has stopped it — in
  which case `bash core/scripts/conduct-pool.sh recycle --worker-id conduct:{id} --force`
  asserts that. A claim you made but never launched is a different case: drop it
  with `bash core/scripts/conduct-pool.sh cancel --worker-id conduct:{id}`.
- **Exit 4** → this worker's own lane is still running. Do not launch: relaunching
  into a live lane's run directory overwrites the artifacts of a process that is
  still working. Queue the task behind the running one and dispatch it from that
  lane's completion, or pick a different worker.

Only an **idle** slot resumes. A running slot is never resumable, which is also
what stops repeated same-worker tasks from stacking lanes inside one recorded
slot and quietly exceeding the advertised cap.

`subagent_id` is the lane's **run id** — the basename of its run directory. It is
the durable handle for continuing a worker's thread, and it is what makes the
pool meaningful for CLI engines, which have no resumable in-session transcript.

## Step 4: Write the brief

The lane cannot see this conversation, so the brief is the entire context. Do at
most two cheap read-only calls yourself to fill it in (branch state, PR number,
file path). Never edit, build, test, or run long commands in the parent.

Open with **who the lane is**, from the worker definition loaded in Step 2 — the
worker's `name` and `description`, then its `instructions` verbatim if it has
any. A lane that is told it is the Code Reviewer, and given that worker's review
procedure, behaves differently from a generic lane handed the same task. That
difference is the entire point of choosing a worker.

Then include:

- **the worker's own material**: the paths to its `skills[].file` entries
  (relative to the worker's `path`), its `context.base` paths, and any
  `knowledge` files. Pass paths, not contents — the lane can read, and the brief
  stays short;
- **its `verification` block**: post-execute checks as done criteria, and every
  `human_checkpoints` entry as an explicit stop-and-report. If
  `approval_required` is true, say so in the brief;
- the goal and its observable done criteria;
- the absolute repo path, branch, and any PR or release identifiers;
- the company slug and the hard policies that bear on the work (repo-anchored
  version-control commands, never push the HQ root, no secrets in output, tests
  are never skipped or loosened);
- on a resume, the path to the worker's previous result file;
- what to do when blocked: report back with the blocker; never wait on the user;
- the report shape: what changed, what was verified and how, links, open risks.

For the `unmatched` slot there is no definition to load — brief it as a
general-purpose lane and say so, rather than inventing a persona for it.

Open the brief with an explicit instruction to execute rather than propose. A
long, carefully scoped brief with no such line reads as a plan request, and the
lane returns in a minute having changed nothing.

## Step 5: Launch the lane, detached

Write the brief to disk and pass only its **path** through `--args`. The runner
takes `--args` as a JSON string on the command line, so inlining a full brief
there is what makes the invocation fragile under nested quoting and long inputs.
The lane can read files; give it a path and keep the command line short.

```bash
TS="$(date -u +%Y%m%d-%H%M%S)"
RUN_DIR="workspace/tmp/workflow-runner/conduct-{worker}-$TS"   # on resume: the existing run dir
mkdir -p "$RUN_DIR"

# The worker's execution.max_runtime, in seconds. 15m -> 900, 5m -> 300, 60m ->
# 3600. Default to 900 when the worker does not declare one, or for `unmatched`.
LANE_TIMEOUT={worker max_runtime in seconds, else 900}

cat > "$RUN_DIR/brief.md" <<'BRIEF'
{the brief from Step 4}
BRIEF

printf '{"brief":"%s","cd":"%s"}\n' "$PWD/$RUN_DIR/brief.md" "{absolute work dir}" > "$RUN_DIR/args.json"

setsid nohup bash -c "
  echo \$\$ > '$RUN_DIR/lane.pid'
  export HQ_CONDUCT_RUN_DIR='$PWD/$RUN_DIR'
  export HQ_CONDUCT_ENGINE='{engine}'
  node core/scripts/workflow-runner.mjs --eval \
    'return await agent(\"Read your brief at \" + args.brief + \" and carry it out now.\", { engine: \"{engine}\", tier: \"exec\", cd: args.cd, label: \"{worker}\", timeoutSecs: $LANE_TIMEOUT })' \
    --args \"\$(cat '$RUN_DIR/args.json')\" --run-dir '$RUN_DIR' > '$RUN_DIR/lane.log' 2>&1
  echo \"CONDUCT_EXIT=\$?\" >> '$RUN_DIR/lane.log'
" > /dev/null 2>&1 < /dev/null &
disown

# Proof of escape: pgid and sid must equal the child's own pid.
ps -eo pid,pgid,sid,args= | grep workflow-runner | grep -v grep
```

Record the lane against its slot, then end the turn:

```bash
bash core/scripts/conduct-pool.sh record --worker-id "conduct:{worker}" \
  --subagent-id "$(basename "$RUN_DIR")" --status running
```

Reply to the user in one line — what was dispatched, to which worker, on which
engine — and stop. Do not poll in the foreground.

Independent tasks go out together in one response, up to the remaining pool
capacity. Dependent tasks chain: launch the next from the previous lane's
completion.

Then arm a waiter as a **background** Bash call so the harness notifies you when
it exits:

```bash
L="{run dir}/lane.log"
P="{run dir}/lane.pid"
starts=0
until grep -q 'CONDUCT_EXIT=' "$L" 2>/dev/null; do
  if [ -s "$P" ]; then
    kill -0 "$(cat "$P")" 2>/dev/null || { echo "lane died without writing its marker"; break; }
  else
    starts=$((starts + 1))
    [ "$starts" -gt 6 ] && { echo "lane never started"; break; }
  fi
  sleep 10
done
tail -30 "$L"
```

The liveness clause is load-bearing: a lane killed before it writes its marker
would otherwise leave the loop unsatisfied forever, and silence must never read
as success. Test the **recorded pid**, not `pgrep -f "{run id}"` — `-f` matches
the whole command line, and the waiter's own `bash -c` contains the run id, so
`pgrep` finds the waiter itself and the killed-lane branch never fires.

Never build the waiter as `tail -f | sed | grep` either — `sed` block-buffers
into a pipe and the completion line never reaches the last stage, so a healthy
lane looks like a hung one. Poll the log; do not stream it.

The waiter is a convenience, not the source of truth. If it is swept, the lane
keeps running and `/conduct status` still finds it.

## Step 5b: Send a message to a lane that is already running

A launched lane is not sealed. Each one carries a drop box, and a hook inside
the lane delivers from it on the lane's next tool event — so a correction
reaches a worker mid-task, without killing it and without waiting for it to
finish.

```bash
bash core/scripts/conduct-inbox.sh send --run-dir "{run dir}" \
  --text "Skip the migration step — Corey says that table is already live."
```

That is the whole operation. The lane picks it up on its next tool call,
treats it as a new instruction from the operator that outranks its brief, and
carries on. Use `--text-file <path>` for anything long or multi-line rather
than fighting shell quoting.

Reach for this when the user changes their mind, when a lane is visibly heading
somewhere wrong, or when something a *different* lane discovered changes what
this one should do. It is one-way. The lane cannot reply; its answer still
arrives the usual way, in its final output.

**Delivery is a queue, not a broadcast.** A message sits in `pending/` until a
lane consumes it, so sending before the lane's first tool call is fine — nothing
is lost. Each message is delivered exactly once, and the consumed copy is kept
under `inbox/claimed/` as a record of what the lane was actually told. To see
what is waiting:

```bash
bash core/scripts/conduct-inbox.sh list --run-dir "{run dir}"
# {"run_dir":"...","pending":1,"delivered":3}
```

**How it lands, by engine.** Every lane is reachable mid-task, but not by the
same route — the engines disagree about how a hook talks to a model, so the
delivery event follows the engine:

| Engine | Event | How it arrives | Cost |
|---|---|---|---|
| codex, claude | `PostToolUse`, plus `Stop` as a backstop | as context, before the model's next step | none |
| grok | `PreToolUse` | as a denied tool call whose reason is the message | the interrupted call |

Grok cannot be handed context on any event — its adapter says so outright and
routes passive-hook output to diagnostics — so the only way to reach a grok lane
is to interrupt it. The message tells it the call was not blocked on its merits
and to retry, so nothing is lost but the round trip. A grok deny reason is
truncated around 1200 characters; keep messages to that engine short.

The corollary is a safety rule the hook enforces: a message is **only** consumed
on an event that can actually reach the model. Draining on an event that cannot
would not delay the message, it would destroy it — and the operator would
believe a correction landed that the lane never saw.

Because it rides the lane's own hooks, this costs nothing when unused: with an
empty queue the hook exits before it touches disk, and the `Stop` arm never
blocks a lane that is legitimately done.

## Step 6: Read the outcome, then verify it

The last lines of `lane.log` say which of several very different things happened:

| Log tail | Meaning |
|---|---|
| `CONDUCT_EXIT=0` | finished — the runner's stdout is the lane's report |
| `CONDUCT_EXIT` non-zero | died — read the tail before blaming the code; a quota or balance refusal (`402`, `403`) looks identical to a build failure from the exit code alone |
| no marker, no process | killed from outside — inspect the work directory before believing nothing happened |
| `TIMEOUT WARNING` repeating, log not growing | hung — kill the process group named in the warning (`kill -- -<pid>`); never pattern-kill |

Then:

1. **Verify independently.** A lane's self-reported success is a claim. Check the
   artifact, the git state, and the repo's own typecheck, lint, and tests
   yourself.
2. On failure, send the errors back to the **same worker** — assign again, which
   resumes its slot — rather than fixing it in the parent. Cap it at three
   rounds, then surface it to the user.
3. Mark the slot idle so the worker is reusable and the cap frees up:
   ```bash
   bash core/scripts/conduct-pool.sh record --worker-id "conduct:{worker}" \
     --subagent-id "{run id}" --status idle
   ```
4. Relay the outcome plainly — done, blocked, or needs a decision — with any
   links. If the lane needs a decision, ask with `AskUserQuestion`, then continue
   the same worker with the answer.

For `status`, print the pool and the live lanes; launch nothing:

```bash
bash core/scripts/conduct-pool.sh list
```

Render it as worker id, status, last task, and run id — the JSON is for you, not
for the user.

## Rules

- **The parent never blocks on a lane.** Launch detached, end the turn, let the
  waiter wake you.
- **Never use the `Agent` tool here.** Lanes are the dispatch mechanism, and they
  are what keeps the child count bounded and the session survivable.
- **The cap is mechanical.** `conduct-pool.sh` owns it. Exit 3 means stop, not
  "launch anyway".
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

## See also

- `/orchestrate` — takes one idea through the same runner from capture to
  finished deliverable, when the arc is known up front rather than arriving task
  by task
- `core/scripts/conduct-pool.sh` — the pool helper, including its cap semantics
- `core/scripts/conduct-inbox.sh` — the per-lane drop box behind Step 5b
- `core/scripts/workflow-runner.mjs` — the multi-engine runner behind every lane
- `core/policies/subagent-fanout-budget.md` — why the cap is stated in the header
