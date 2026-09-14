# Pool lane protocol

The one description of how an HQ orchestrator claims, validates, uses and
releases a session worker lane. `/execute-task` and `/run-project` both follow
it; neither restates it, because every time the two descriptions drifted apart
one of them was wrong.

A lane is a long-lived sub-agent bound to a worker id for the life of the
session. The pool is the record of which lanes exist, and `conduct-pool.sh`
is the only thing allowed to decide whether a new one may open.

## 1. Namespaces — who claims what

| Claimer | Lane id | Why |
|---|---|---|
| A worker **phase** (`/execute-task` step 6c) | the bare worker id — `backend-dev` | the lane does the domain work |
| A **story coordinator** (`/run-project` step 3b) | `story:{worker-id}` | the wrapper only runs `/execute-task`; its phases claim the bare id |
| The preflight explorer | `explorer` | one planning lane per session |
| The regression gate | `regression-gate` | one gate lane, reused at every cadence |
| `/conduct` | `conduct:{worker-id}` | its `subagent_id` is a workflow-runner run directory, not a `Task` / `spawn_agent` handle |

The `/conduct` row is not tidiness. A lane claimed by `/conduct` and resumed by
`/execute-task` would hand a run-directory name to a runtime expecting a
sub-agent handle, and the two follow different ownership rules — only the
protocol's lanes carry an `owner.json` stamp. Sharing the bare id would let a
session that used both silently cross them.

**A coordinator must never claim the bare worker id.** It runs `/execute-task`,
whose `api_development` phase claims `backend-dev`; a coordinator already
holding `backend-dev` sends that phase to exit 4, where it waits for a lane the
coordinator itself is holding while the coordinator waits for the phase. Nothing
in the pool can break that cycle.

The delimiter is a **colon**. `conduct-pool.sh` restricts ids to
`[A-Za-z0-9._:-]` and rejects anything else outright, so `story/backend-dev`
exits 1 and claims nothing at all.

## 2. Claim

```bash
bash core/scripts/conduct-pool.sh assign --worker-id "{lane-id}" --task "{short label}"
```

A slot moves through four states, and the gap between the first two is where
`cancel` lives:

| state | meaning |
|---|---|
| `claimed` | `assign` granted the lane; nothing is dispatched into it yet |
| `running` | `record --status running` attached a sub-agent; work is live |
| `idle` | `record --status idle` released it; the next `assign` resumes it |
| `recycled` | retired; a tombstone kept for provenance, not counted against cap |

Read both the JSON and the exit code:

| Result | Meaning | Do this |
|---|---|---|
| `{"action":"spawn","worker_id":…}` | no live lane | dispatch cold (§5) |
| `{"action":"resume","worker_id":…,"subagent_id":…}` | an idle lane exists | validate it (§3), then continue it (§5) |
| `…,"recycled":"<other-id>"` | pool was full; the LRU idle slot was retired | dispatch cold; name the retired lane in the log |
| exit 3 | pool at cap, every slot running | **wait.** Do not dispatch. See §2a before reaching for `recycle` — it will refuse a running lane |
| exit 4 | this lane is already **running** | **wait.** Resuming would relaunch into a run directory a working process still owns |

Exits 3 and 4 change nothing in the pool. Dispatching past them is exactly how a
run exceeds `CONDUCT_POOL_CAP` (default 8) or clobbers a live lane.

## 2a. Recycling is a pool operation, not a process one

`recycle` frees a slot. It does **not** stop the sub-agent in it, and it never
could — the pool records ids, it does not own processes. So retiring a *running*
lane is a lie the rest of the system believes: the cap is enforced against the
pool, so the real child count goes over it, and whatever claims the slot next
shares a run directory with a process still writing to it.

`conduct-pool.sh recycle` therefore **refuses a running lane with exit 5**. When
the pool is full and every slot is running, the answer is to wait. Only after a
lane has actually reported, or you have stopped it and confirmed it stopped, may
you retire it — `--force` exists for that case and asserts you have done so.

A claim you never dispatched is a different thing, and has its own verb.
`assign` marks a slot `running` before anything is launched, so a caller that
backs out — because the slot's ownership stamp names another tenant (§3), or
because it decided not to proceed — would otherwise be stuck behind that same
refusal. `cancel --worker-id <id>` covers that window: it retires the slot only while it
is still `claimed`, and refuses once `record --status running` has moved it on.
That is a fact the helper owns, not an assertion it accepts, which is why
`cancel` needs no `--force` and cannot be used to abandon a live lane.

The status is what it keys on, deliberately — an empty `subagent_id` would not
have worked. A **resume** claim keeps the previous lane's id while it waits to be
dispatched, so an emptiness test would have refused exactly the cross-tenant
reset this verb exists for.

Both `recycle` and `cancel` **clear the slot's `handoffs.jsonl` and
`owner.json`**. That is
deliberate and it is the point: recycling is how a fat lane is discarded, so
leaving the file behind means the next claim of the same worker — which passes
the ownership check, being the same company and project — reads back the entire
transcript the recycle was meant to drop, and it grows without bound across
recycles. A recycled lane always restarts cold.

## 3. Validate ownership — before dispatch, on every path

A lane that answers `resume` may have been serving a different project, or a
different company, earlier in this session. Resuming it carries that context in.
So this runs **after `assign` and before the spawn/resume split**, never inside
one branch: a runtime with a native resume primitive carries the lane's whole
prior transcript and is the path that most needs the check.

```bash
bash core/scripts/hq-session.sh current      # prints the session id -> SID
mkdir -p "workspace/sessions/$SID/pool/{lane-id}"
```

`mkdir -p` comes first. `assign` writes a pool entry in the session `meta.yaml`
and nothing on disk, so on a lane's first use the slot directory does not exist
yet and any read, delete or redirect into it fails with
`No such file or directory` before the phase ever dispatches.

The slot directory lives under the **session**, beside the pool state that owns
the slot, and never under the project. Two reasons, both load-bearing:

- A project slug is not unique across companies. Keyed by project, one tenant's
  lane history is read as another's — a category-1 cross-company leak.
- A project-keyed file outlives the session that wrote it. A later run on the
  same slug reads yesterday's entries as "already done in this session" and
  skips live work.

Then read `{slot dir}/owner.json`. If it is absent, unreadable, or names a
different company or project than this work:

1. `conduct-pool.sh cancel --worker-id "{lane-id}"`, then `assign` again. A
   retired slot comes back as `spawn`, so you cannot resume into foreign
   context.

   Use `cancel`, not `recycle`. You are still before dispatch here: the slot is
   `claimed`, which is exactly the window `cancel` is scoped to. It works whether
   this claim answered `spawn` or `resume` — a resume claim still carries the
   previous lane's `subagent_id`, and `cancel` keys on the status, not on that.
2. Delete `{slot dir}/handoffs.jsonl` and write a fresh `owner.json`.
   **Reinitialise — do not merely decline to read.** The appends in §6 are
   unconditional, so a file left in place collects this owner's entries under
   the previous owner's stamp, and the original owner returns to find its own
   stamp matching with foreign phases inside it.
3. Dispatch cold.

```bash
printf '{"company":"%s","project":"%s","session_id":"%s"}\n' "{co}" "{project}" "$SID" \
  > "workspace/sessions/$SID/pool/{lane-id}/owner.json"
```

Never repair a mismatched stamp in place and never read past one. A stale or
foreign lane history is worse than no history, because the worker acts on it as
fact.

## 4. Mark the lane running — before anything blocks in it

This section interleaves with §5; read both before dispatching.

The slot is `claimed` from `assign` until this call, and a `claimed` slot is one
`cancel` may retire as undispatched. So the window between launching work and
recording it has to be closed before anything can block inside it. Recording
*after* the wait returns would leave live work marked `claimed` for its whole
duration — precisely the state `cancel` is allowed to retire.

The runtimes differ in when they hand you an id, and the sequence accounts for
that rather than assuming:

**Codex** — `spawn_agent` returns an id and `wait_agent` blocks separately, so
record between them:

```
spawn_agent(...)   -> agent id
```

```bash
bash core/scripts/conduct-pool.sh record --worker-id "{lane-id}" \
  --subagent-id "{agent id}" --status running --task "{short label}"
```

```
wait_agent(...)    -> blocks
```

**Claude Code** — `Task` dispatches and blocks in one call, so there is no
between. Record first with the literal `pending` as the id, and replace it when
the call returns (§6):

```bash
bash core/scripts/conduct-pool.sh record --worker-id "{lane-id}" \
  --subagent-id pending --status running --task "{short label}"
```

```
Task(...)          -> dispatches and blocks
```

Either way the lane is `running` for the whole time work is live in it, and
never `claimed`.

A lane left `running` because dispatch threw before returning is the
`recycle --force` case in §2a: stop the sub-agent, confirm it stopped, retire.

## 5. Dispatch — spawn, resume, or the honest fallback

**Spawn** (`action=spawn`): send the full prompt via the runtime's sub-agent
tool — Claude Code `Task`, Codex `spawn_agent` + `wait_agent`.

**Resume** (`action=resume`): if the runtime can re-enter an existing sub-agent
by id, do that and send only the delta — the ask and the incoming handoff. Do
not resend the full prompt; the lane already holds it, and resending is the cost
the pool exists to avoid.

**Fallback, when the runtime has no resume primitive.** Neither Claude Code's
`Task` nor Codex `spawn_agent` can re-enter an existing sub-agent — both always
start a new one. Do not pretend otherwise, and do not leave the branch
unimplemented: an `assign` that answered `resume` has already marked the slot
`running`, so a coordinator that cannot act on it leaves the lane stuck and
every later claim for that worker exits 4.

Instead, keep the slot and carry its continuity on disk. Dispatch a new
sub-agent with the full prompt, prefixed by:

```
You are resuming your own lane. Every unit of work you already ran in this
session is recorded in {slot dir}/handoffs.jsonl — read it first and do not
redo anything it shows as done. That file belongs to this session and this
company only; if it is absent, start from the brief.
```

Then `record` the new sub-agent id against the **same** slot. The cap counts
lanes, not restarts, so a fallback restart never consumes a second slot.

## 6. Release the lane, and record what it did

**Release on process completion, not on result validation.** The two are
separate facts and only the first governs the slot: the moment the sub-agent or
lane is gone, the slot is reusable, whatever it returned. Gating the release on a
valid reply strands the slot exactly when a caller needs it most — every retry
path (`/run-project`'s one retry on malformed JSON, `/execute-task`'s debugger
recovery) re-`assign`s the same worker and gets exit 4, waiting on something that
has already exited. Release first, then parse.

So: release the slot, recording the real sub-agent id alongside it if you
dispatched with `pending`. Then append the handoff or return JSON as one line to
`{slot dir}/handoffs.jsonl` — this append is unconditional, which is why §3
reinitialises on a mismatch rather than merely declining to read.

```bash
bash core/scripts/conduct-pool.sh record --worker-id "{lane-id}" \
  --subagent-id "{sub-agent id}" --status idle
```

A lane left marked `running` after its work returns is **never resumable**:
every later `assign` for that worker exits 4 and the run stalls. Release it even
when the work failed, returned garbage, or the sub-agent died — or `recycle` the
slot — before moving on.

**The one exception is a lane you could not confirm dead.** "The sub-agent died"
is a claim about the wrapper process, and the engine is not in its group — the
runner spawns it detached. So a lane that missed its deadline without stopping
cleanly, *and equally* one the waiter reported as `died` or `never-started`,
may still be running with a handle nobody holds. Dispatch protocol §5 has the
confirmation to run — the journalled engine pgid — and it applies to every
outcome, not just the timeout. Until it reports the group empty, do not release
or force-recycle that slot: an unconfirmed process and its replacement would
write over each other. Leave it `running`, say so, and let a human decide.

When a lane's context grows fat enough to hurt — long phases, many stories on
one worker, or a return that shows it losing earlier detail — compact or recycle
that slot. Do not open a second lane for the same worker to escape it.

## 7. Nesting budget

A coordinator lane holds a slot **while waiting on** a phase lane. Fill the pool
with coordinators and every one of them blocks on exit 3, with nothing running
that could release a slot — a deadlock the pool cannot detect, because from its
side every slot is legitimately busy.

So an orchestrator that nests must leave room:

```
max_coordinators = max(1, (CONDUCT_POOL_CAP - 2) / 2)      # integer division
```

**3** at the default cap of 8. The `- 2` is the explorer and regression-gate
slots, which stay claimed as `idle` and still count against the cap; the `/ 2`
guarantees every live coordinator can still claim the one phase lane it needs.

The `max(1, …)` is not cosmetic. `conduct-pool.sh` accepts any positive
`CONDUCT_POOL_CAP`, and the bare formula yields **0** at a cap of 2 or 3 — which
would permit no coordinator at all and stall the run before its first story. At
those caps the reserved pair is what does not fit, so give up the reservation
rather than the work: recycle the explorer slot once its plan is captured and
the gate slot after each gate, then run exactly **one** coordinator, serially.

A cap of **1** cannot host a coordinator and its phase at the same time, so
nested execution is structurally impossible there. Do not improvise around it:
say so and stop, and offer raising `CONDUCT_POOL_CAP` or running `--interactive`
(which is parent-driven and claims no slots at all).
