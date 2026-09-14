# Lane dispatch protocol — how a brief becomes a detached lane

`/conduct` and `/run-project` both hand work to a **detached lane**: a
`core/scripts/workflow-runner.mjs` process running one `agent()` call against a
headless coding-agent CLI. This file is the single description of that
mechanism. Both skills defer to it rather than restating it, because the last
time this protocol lived in two places one copy was wrong for three review
rounds.

Slot accounting is a separate concern and lives in
`.claude/skills/_shared/pool-lane-protocol.md`. Claim the slot there, dispatch
into it here. The two are ordered: **assign → dispatch → record running →
wait → record idle.**

## 1. Why detached, and what it buys

- **A lane is an OS process, not an in-session sub-agent.** It keeps running
  when the parent session compacts, restarts, or ends. Nothing in this protocol
  uses the `Agent` tool.
- **A host with no in-session sub-agent primitive can still dispatch.** That is
  the reason `/run-project` defaults here rather than to `spawn_agent`.
- **A lane can be corrected while it runs** (§6) instead of being killed and
  relaunched.
- **`setsid` is mandatory, not decorative.** A child left inside the session's
  process tree is swept at the turn boundary, minutes after the turn that
  launched it — which reads as an unexplained silent failure. `setsid` puts the
  lane in its own process session, where the sweep cannot reach it.

## 2. Resolve one engine per run, before you brief anything

```bash
command -v codex grok claude
```

Configuration is not availability: an engine whose CLI resolves can still refuse
on a quota or balance error, and a refusal costs the same sixty seconds whether
it interrupts a throwaway probe or a fully briefed lane.

**If no engine CLI resolves, this protocol is unavailable.** Say so and fall
back to the caller's in-session path (`/run-project` §3b's `spawn_agent`
fallback), or hand the blocker to the user naming which engines were tried. Do
not discover this at dispatch time, once per story.

### The roster

| Choice | `{engine}` | Best for |
|---|---|---|
| `codex` (default) | `codex` | implementation, landing work, CI babysitting, fixes |
| `grok` | `grok` | fast implementation, a cheap second opinion |
| `claude` | `claude` | review, design, judgment-heavy work |

**Resolution is deterministic, and happens once.** In order: an engine the user
named explicitly; else the caller's own default if it declares one; else the
first of `codex`, `grok`, `claude` that resolves. Never leave `{engine}`
unexpanded, and never re-resolve per lane — **record the choice for the run and
reuse it for every lane in that run.** Mixed engines across the lanes of one run
give you results that are not comparable and a failure you cannot attribute.

One difference that is not about quality: all three can be corrected while they
run (§6), but only codex and claude take a message quietly. A grok lane has to be
interrupted — the message arrives as a denied tool call — which costs it the step
it was about to take. For work you expect to steer often, that is a reason to
prefer codex.

## 3. The brief goes on disk; the command line carries a path

The runner takes `--args` as a JSON string on the command line, so inlining a
brief there is what makes the invocation fragile under nested quoting and long
inputs. A lane can read files. Give it a path.

**The run dir is session-scoped and minted atomically.** Both halves are load
bearing. A timestamp alone collides: `explorer` and `regression-gate` are
constant lane ids and story ids like `US-001` repeat across projects, so two
sessions dispatching within the same second computed the *same* path — and the
second silently overwrote the first's brief, args, pids, deadline and log. Pools
are session-scoped, so nothing serialises those launches. That is a lane reading
another tenant's brief, not just a clobbered log. `$SID` separates the sessions;
`mktemp -d` closes the race inside one.

**The run dir belongs to the session that minted it, and so does the pool
slot.** `conduct-pool.sh` resolves the session from the environment, and the run
dir is under `$SID`, so a *different* session inspecting the same project sees
an empty pool and no run dirs while the lanes are still live. Any caller that
supports resuming across sessions has to persist the originating `$SID`
somewhere durable and pass it back with `conduct-pool.sh --session-id <sid>`.
Session scoping is what stops two sessions colliding; it is also what makes
recovery an explicit act.

**Callers name `{caller}` and `{lane}`, never a path.** The run dir is minted
here and only here; a caller that writes its own path reintroduces the collision
the moment this template changes under it. Read the minted `$RUN_DIR` back if you
need it.

**Every dispatch mints a fresh run dir — including a resume.** Reusing a
completed lane's directory looks tidy and is a race: its `lane.log` still holds
`CONDUCT_EXIT=` and its pid files still name the finished process, while the new
child does not truncate that log until it is already detached and running. A
waiter armed in between reads the *old* marker, calls the new lane finished, and
releases a slot that is still live. Clearing the files first only narrows the
window. Lane continuity does not live here anyway — it lives in the slot's
`handoffs.jsonl` (pool protocol §5), which is keyed by worker, survives the run
dir, and is what a resumed lane actually reads.

**`$SID` is the run's owner, not "whoever is dispatching".** For a first
dispatch those are the same session and the line below is right. For a dispatch
that belongs to a run some *earlier* session started — a resumed story, a retry
after recovery — they are not, and recomputing it is how the recovery fix above
gets undone: the lane would export the new session's id, mint its run dir there,
and an unqualified `record` would write into a pool that never assigned the
slot, leaving a live lane untracked while the original slot stays `claimed`. A
caller that persists an owning session id (`/run-project` keeps it in
`state.json`) uses that value here instead, and passes `--session-id <owner>` on
every `conduct-pool.sh` call for the lane. One session id per run, chosen once,
end to end.

```bash
SID="$(bash core/scripts/hq-session.sh current)"   # or the run's recorded owner
BASE="workspace/tmp/workflow-runner/$SID"
mkdir -p "$BASE"
RUN_DIR="$(mktemp -d "$BASE/{caller}-{lane}-XXXXXX")"

cat > "$RUN_DIR/brief.md" <<'BRIEF'
{the brief}
BRIEF

jq -n --arg brief "$PWD/$RUN_DIR/brief.md" --arg cd "{absolute work dir}" \
  '{brief:$brief, cd:$cd}' > "$RUN_DIR/args.json"
```

**Build `args.json` with an encoder, not with `printf`.** A `%s` substitution
emits whatever the path contains: a double quote or a backslash in the HQ
install path or the target work dir produces invalid JSON, and the runner fails
on `--args` before the lane exists — with the failure in a log nobody is
watching yet. `jq -n --arg` escapes both, and it is already a dependency here
(§5 and §7 use it).

## 4. Launch

```bash
LANE_TIMEOUT={worker max_runtime in seconds, else 900}   # $SID and $RUN_DIR are from §3

# The real bound (§5). Write it to disk, do not keep it in a shell variable:
# the waiter is a separate background call in a separate process, and a
# variable set here is empty there.
echo $(( $(date +%s) + LANE_TIMEOUT )) > "$RUN_DIR/deadline"

# Everything the detached body needs goes through the ENVIRONMENT. Nothing is
# interpolated into the nested shell string — see below.
export LANE_RUN_DIR="$RUN_DIR"
export LANE_RUN_DIR_ABS="$PWD/$RUN_DIR"
export LANE_TIMEOUT
export HQ_SESSION_ID="$SID"
export HQ_CONDUCT_ENGINE='{engine}'

setsid nohup bash -c '
  echo $$ > "$LANE_RUN_DIR/lane.pid"
  export HQ_CONDUCT_RUN_DIR="$LANE_RUN_DIR_ABS"
  node core/scripts/workflow-runner.mjs --eval \
    "return await agent(\"Read your brief at \" + args.brief + \" and carry it out now.\", { engine: \"$HQ_CONDUCT_ENGINE\", tier: \"{tier}\", cd: args.cd, label: \"{lane}\", timeoutSecs: $LANE_TIMEOUT })" \
    --args "$(cat "$LANE_RUN_DIR/args.json")" --run-dir "$LANE_RUN_DIR" > "$LANE_RUN_DIR/lane.log" 2>&1 &
  echo $! > "$LANE_RUN_DIR/runner.pid"
  wait $(cat "$LANE_RUN_DIR/runner.pid")
  echo "CONDUCT_EXIT=$?" >> "$LANE_RUN_DIR/lane.log"
' > /dev/null 2>&1 < /dev/null &
disown

# Proof of escape: pgid and sid must equal the child's own pid.
#
# Two pids are recorded, and §5 needs both. lane.pid is the wrapper and, because
# setsid made it a group leader, also the pgid. runner.pid is node — the ONLY
# process that can shut this lane down cleanly, because the engine CLI is
# spawned detached: true (its own process group) and the runner's killTree is
# the only code that holds that group id.
ps -eo pid,pgid,sid,args= | grep workflow-runner | grep -v grep
```

**The nested body is single-quoted and interpolates nothing.** It used to be a
double-quoted string with `$PWD`, `$RUN_DIR` and `$SID` substituted into
single-quoted values inside it. An apostrophe anywhere in the HQ checkout path —
the one value here a user genuinely controls — closes those quotes early, and
the lane dies before it starts, in a log nobody is watching yet. Passing them
through the environment removes the whole class: the outer shell sets the
variables, the inner shell reads them, and no path text is ever parsed as shell.
It also removes the two-level escaping that made this the most error-prone block
in the protocol.

**`{tier}` is the caller's choice and is never implicit.** `exec` is the
throughput model, `plan` the flagship one. Execution work takes `exec`; analysis,
review, planning and design take `plan`. A preflight dispatched at `exec` quietly
does its thinking on the wrong model.

**`timeoutSecs` is a *soft* timeout.** `workflow-runner.mjs` prints a repeating
`TIMEOUT WARNING` and explicitly **does not kill** the child. It is a diagnostic,
not a bound. The wall-clock bound is the `deadline` file, enforced by the waiter
in §5 — without it a hung lane blocks its caller forever, waiting for a
`CONDUCT_EXIT` marker the runner will never write.

**The deadline goes on disk because the waiter is a different process.** Launch
and wait are two separate Bash calls, so a shell variable set at launch is empty
in the waiter — and `[ "$(date +%s)" -ge "" ]` errors on every iteration, which
loops silently and bounds nothing. On disk it also survives the parent
restarting and re-arming a waiter against a lane that is already running.

**`HQ_SESSION_ID` is exported deliberately.** The runner passes its environment
through to the engine, and anything the lane runs that touches the pool —
`/execute-task` claiming phase lanes inside a story lane, most of all — resolves
its session from `HQ_SESSION_ID` first and the `.current` file only as a
fallback. Without the export, a lane that outlives its parent session reads
whatever `.current` names by then and claims slots in a **different session's**
pool, which is how the cap silently stops holding.

## 5. Record, then wait in the background

```bash
bash core/scripts/conduct-pool.sh record --worker-id "{lane-id}" \
  --subagent-id "$(basename "$RUN_DIR")" --status running
```

The run-dir basename is the lane's handle. Add `--session-id "$SID"` when `$SID`
is a run's recorded owner rather than the current session — `record`, `recycle`
and `cancel` all take it, and without it the write lands in the dispatching
session's pool while the slot lives in the owner's. Record it **immediately after
launch** — a slot left `claimed` while a lane is live is one `cancel` may retire
as undispatched (pool protocol §4).

Then arm a waiter as a **background** call so the harness notifies you when it
exits. Never poll in the foreground:

```bash
D="{run dir}"
L="$D/lane.log"
P="$D/lane.pid"
deadline="$(cat "$D/deadline" 2>/dev/null)"
[ -n "$deadline" ] || { echo "no deadline file — refusing to wait unbounded"; exit 1; }
starts=0
outcome=exited
until grep -q 'CONDUCT_EXIT=' "$L" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$deadline" ]; then outcome=deadline; break; fi
  if [ -s "$P" ]; then
    # Ask whether the lane's own group still has members, not whether the
    # wrapper is alive. This cannot see the engine (spawned detached, its own
    # group) and does not need to: if the runner is gone the wrapper writes
    # CONDUCT_EXIT, so an empty group with no marker means the lane died.
    pgrep -g "$(cat "$P")" >/dev/null 2>&1 || { outcome=died; break; }
  else
    starts=$((starts + 1))
    [ "$starts" -gt 6 ] && { outcome=never-started; break; }
  fi
  sleep 10
done
echo "lane outcome: $outcome"
tail -30 "$L"
```

Reading the missing-deadline case as "wait forever" would reintroduce exactly the
bug the file is there to prevent, so the waiter refuses to start without one.

**No outcome releases the slot until the engine group is confirmed empty.**
Every one of the four exits below is a statement about the *wrapper* or the
*runner*, and the engine is in neither of their groups — the runner spawns it
`detached: true`. The confirmation that closes that gap is below the branches,
and it runs **last**, after whatever teardown the branch called for.

Four ways out, and they are not interchangeable:

- **`exited`** — the marker is there. Confirm the group, then read the outcome
  (§7). The marker is the *runner's* exit, not the tree's: `child.on('close')`
  fires when the engine's group leader goes, so a descendant can outlive it.
- **`died`** / **`never-started`** — the *wrapper* is gone with no marker. The
  liveness clause is load-bearing: without it these cases leave the loop
  unsatisfied forever, and silence must never read as success. But the wrapper
  disappearing says nothing about the engine — a SIGKILLed wrapper cannot take
  its runner's detached child with it — so these are exactly the paths where
  confirming the group matters most. Releasing on `died` without it starts a
  replacement worker on top of a live engine.
- **`deadline`** — **the lane is still running.** This is the only exit that
  leaves a live process behind, and it is the case `timeoutSecs` does not cover:
  the runner's soft timeout warns and keeps going, so a hung lane would otherwise
  hold its caller forever. Stop it explicitly, and confirm:

  **Ask the runner to stop; do not try to out-kill it.** Signal
  `runner.pid` — node — and wait for the wrapper's `CONDUCT_EXIT` marker as
  proof:

  ```bash
  kill -TERM "$(cat "$D/runner.pid")" 2>/dev/null
  stopped=no
  for _ in $(seq 1 30); do
    grep -q 'CONDUCT_EXIT=' "$L" 2>/dev/null && { stopped=yes; break; }
    sleep 1
  done

  if [ "$stopped" = no ]; then
    kill -KILL -- -"$(cat "$P")" 2>/dev/null
    echo "WARNING: the runner never acknowledged. Do NOT recycle this slot."
  fi
  ```

  Then run the confirmation below with `graceful_attempted=yes`. This is the
  only branch that sets it, and only *here* — after the runner has had its
  30 seconds — because that flag is what authorises a SIGKILL of the engine
  group. The marker plus `engine_gone=yes` is the clean stop; anything else is
  unconfirmed.

  **Why the runner and not the group.** `workflow-runner.mjs` spawns the engine
  CLI with `detached: true`, so the engine leads *its own* process group — not
  the wrapper's. Signalling the wrapper group therefore never reaches the engine,
  and `pgrep -g "$pgid"` cannot see it either, so a group that looks empty proves
  nothing. The runner's `killTree` is the only code that holds the engine's group
  id. Signal the runner and it does the teardown correctly.

  **Why wait for the marker, and why 30s.** The runner's own SIGTERM handler
  SIGTERMs the engine tree and escalates to SIGKILL after **5 seconds**. A waiter
  that sleeps 5s and then SIGKILLs the runner races that timer dead-on: kill the
  runner at t=5s and its escalation may never fire, orphaning the engine. So the
  grace must be comfortably longer than the runner's.

  **But the marker alone is not proof the tree is down.** The runner's
  `child.on('close')` fires when the engine's group *leader* exits and then calls
  `onAllChildrenGone` immediately — so a descendant that outlives the leader
  retires the runner before its own SIGKILL escalation ever runs, and
  `CONDUCT_EXIT` appears over a group that still has members. Verify it, using
  the pgid the runner journals at spawn — the runner is the only party that can
  name a group it created with `detached: true`:

  A marker with an empty group is a clean stop. A marker with survivors is not:
  the shared confirmation SIGKILLs that group directly — safe there, because
  unlike the wrapper group this *is* the engine — and only reports
  `engine_gone=no` if something survives even that, which downgrades this stop
  to unconfirmed.

  **The unconfirmed case is a real state; do not paper over it.** It is reached
  from every branch, not just this one: any outcome with `engine_gone=no`, and
  any `deadline` whose marker never came. If the marker
  never arrives, SIGKILLing the wrapper group is a last resort that explicitly
  does *not* clear the engine — a SIGKILLed runner cannot run `killTree`. Leave
  the slot `running`, say so, and let a human decide. Retiring it
  (`recycle --force`) would put a second worker in a lane the first is still
  writing to, which is the exact failure `recycle`'s running-lane guard exists to
  prevent; forcing past that guard on an unverified process defeats it. Only a
  clean stop earns the recycle. Test the **recorded pid**, not `pgrep -f "{run id}"` — `-f` matches
the whole command line, and the waiter's own `bash -c` contains the run id, so
`pgrep` finds the waiter itself and the killed-lane branch never fires (bash
discipline rule 14).

### Confirming the engine group — run this last, on every outcome

```bash
# yes ONLY on the deadline branch, after the runner has had its 30s. That flag
# is what authorises the SIGKILL: killing an engine we never asked to stop
# takes it down mid-write, in a half-finished file or a half-made commit.
graceful_attempted={yes on the deadline branch after its wait, else no}

engine_gone=yes
epgid="$(jq -r 'select(.event=="agent-spawned")|.pgid' "$D/journal.jsonl" 2>/dev/null | tail -1)"
if [ -n "$epgid" ] && pgrep -g "$epgid" >/dev/null 2>&1; then
  if [ "$graceful_attempted" = yes ]; then
    kill -KILL -- -"$epgid" 2>/dev/null   # safe: this IS the engine's group,
    sleep 2                               # named by the process that made it,
  fi                                      # and it has already refused SIGTERM
  pgrep -g "$epgid" >/dev/null 2>&1 && engine_gone=no
fi
echo "engine group: $engine_gone"
```

**Observation first, force only after a refused request.** The runner is the
only thing that can stop the engine politely — `killTree` SIGTERMs the tree and
escalates on its own timer — so the sequence is always: ask the runner, wait,
*then* consider force. A confirmation that SIGKILLs on sight would run before
the deadline branch ever signalled the runner and would defeat the graceful path
it exists to protect, tearing a timed-out worker down mid-write. On `exited`,
`died` and `never-started` there was no request to refuse, so a survivor is
observed and reported, never killed.

`engine_gone=no` means a process is still working in the lane's repo. Whatever
the outcome said, the slot stays `running` and a human decides. An absent
`epgid` — the lane died before the runner spawned an engine — is not a survivor:
that is `never-started`, and there is nothing to confirm.

Never build the waiter as `tail -f | sed | grep`: `sed` block-buffers into a
pipe, the completion line never reaches the last stage, and a healthy lane looks
like a hung one.

The waiter is a convenience, not the source of truth. If it is swept, the lane
keeps running and the run dir still holds the outcome.

## 6. Correcting a lane mid-flight

A launched lane is not sealed. Each carries a drop box, and a hook inside the
lane delivers from it on the lane's next tool event, so a correction reaches the
worker without killing it and without waiting for it to finish:

```bash
bash core/scripts/conduct-inbox.sh send --run-dir "{run dir}" --text "{correction}"
```

Codex and claude lanes take a message quietly. A grok lane has to be interrupted
— the message arrives as a denied tool call — which costs it the step it was
about to take. For work you expect to steer often, that is a reason to prefer
codex. Use `--text-file <path>` for anything long rather than fighting shell
quoting, and `conduct-inbox.sh list --run-dir …` to see what is still pending.

## 7. Reading the outcome

The lane's return value is in the run dir, not in a tool result. Read it there,
compactly — never by pasting a full log into the parent transcript.

**Do not read the payload out of `lane.log`.** That file is the runner's whole
stdout: narration, warnings, and — last — `JSON.stringify(result)`
(`workflow-runner.mjs:1526`). A schema-less `agent()` returns the engine's reply
as *text*, so what lands there is a JSON **string** whose content is the worker's
JSON, not the worker's object. `jq -e .` on it succeeds and every field access
then comes back empty, which reads as "the worker returned nothing" when the
worker in fact returned everything. `lane.log` is for the `CONDUCT_EXIT` marker
and for a human tail when something went wrong; it is not the result channel.

**Read `agent-1.result.json`.** Each lane runs exactly one `agent()` call, so
`n` is always 1. The runner writes `{ key, label, value }` there
(`workflow-runner.mjs:1169-1173`), where `value` is precisely what `agent()`
returned:

```bash
raw="$(jq -r '.value' "$D/agent-1.result.json")"     # the worker's reply, as text
printf '%s' "$raw" | jq -e '.'                        # now parse it as the contract
```

Two calls, not one: the outer `jq` unwraps the runner's envelope, the inner one
parses the worker's JSON. Collapsing them into a single `jq` is the exact
mistake described above.

If `agent-1.result.json` is missing — the runner writes it best-effort, and a
lane that died before finishing never gets one — fall back to
`agent-1.last.md`, the engine's raw final reply
(`workflow-runner.mjs:922`, `:1108`). A repair pass writes
`agent-1.repair.last.md` alongside it; when both exist the repair one is the
reply that was accepted.

A caller that imposed a return contract (`/run-project` requires story JSON)
validates it here, at the same point an in-session caller would have validated a
`wait_agent` return. Everything downstream of that — the retry on malformed
JSON, the proof gates, the release of the slot — is unchanged by the lane being
detached.

**Release the slot as soon as the lane is gone,** before branching on what it
returned (pool protocol §6). A failed lane's slot is just as reusable as a
successful one's, and every recovery path re-`assign`s.

"Gone" means both halves of §5: the waiter reached an outcome **and**
`engine_gone=yes`. A slot released on the outcome alone can be handed to a
replacement worker while the old engine is still committing to the same repo.
