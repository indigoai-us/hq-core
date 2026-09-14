#!/usr/bin/env bash
# orchestrator-skills-dispatch-lanes.test.sh — pins /run-project and /conduct to
# the shared detached-lane dispatch protocol.
#
# /run-project used to dispatch every story as an in-session sub-agent and block
# on wait_agent, so a compaction or a session restart killed the run. It now
# defaults to the same detached workflow-runner lane /conduct has always used.
# That put the same mechanism in two skills, which is exactly the shape that
# produced three rounds of helper/consumer drift on the pool work: the fix is a
# shared protocol file plus these checks, which hold the protocol rather than
# holding two copies of it.
#
# These pull two ways on purpose. Detaching must not drop the JSON return
# contract, the proof gates, the pool accounting, or the in-session fallback for
# a host with no engine CLI; and the blocking spawn-and-wait story loop must not
# creep back in as the default.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILLS="${HQ_ORCH_SKILLS_DIR:-$ROOT/.claude/skills}"
RUN_PROJECT="$SKILLS/run-project/SKILL.md"
CONDUCT="$SKILLS/conduct/SKILL.md"
DISPATCH="$SKILLS/_shared/lane-dispatch-protocol.md"
POOL_PROTO="$SKILLS/_shared/pool-lane-protocol.md"
RUNNER="$ROOT/core/scripts/workflow-runner.mjs"
INBOX="$ROOT/core/scripts/conduct-inbox.sh"

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok — $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
flatten() { tr '\n' ' ' < "$1" | tr -s ' '; }

for f in "$RUN_PROJECT" "$CONDUCT" "$DISPATCH" "$POOL_PROTO"; do
  [ -f "$f" ] || fail "missing $f"
done
flatten "$RUN_PROJECT" > "$TMP/run.flat";      RUN_FLAT="$TMP/run.flat"
flatten "$CONDUCT"     > "$TMP/conduct.flat";  CON_FLAT="$TMP/conduct.flat"
flatten "$DISPATCH"    > "$TMP/dispatch.flat"; DIS_FLAT="$TMP/dispatch.flat"

echo "the shared dispatch protocol exists and names the machinery it depends on"
[ -f "$RUNNER" ] || fail "missing $RUNNER — the protocol dispatches through a runner that does not ship"
[ -f "$INBOX" ] || fail "missing $INBOX — the protocol documents a drop box that does not ship"
grep -q 'workflow-runner.mjs' "$DISPATCH" \
  || fail "the dispatch protocol must name the runner it launches"
grep -q 'setsid' "$DISPATCH" \
  || fail "the dispatch protocol must require setsid — a child left in the session tree is swept at the turn boundary"
ok "lane-dispatch-protocol.md ships and references real machinery"

echo "the protocol exports HQ_SESSION_ID into the lane"
# Without it a lane that outlives its parent resolves the session from .current
# and claims slots in a different session's pool, so the cap stops holding.
grep -q "export HQ_SESSION_ID" "$DISPATCH" \
  || fail "the lane must carry HQ_SESSION_ID or its nested pool claims land in another session"
grep -qi 'different session' "$DIS_FLAT" \
  || fail "the protocol must say why the export matters, not just perform it"
ok "a lane inherits its parent's session id explicitly"

echo "the protocol refuses to discover a missing engine at dispatch time"
grep -q 'command -v codex grok claude' "$DISPATCH" \
  || fail "the protocol must probe for an engine CLI before briefing one"
grep -qi 'this protocol is unavailable' "$DIS_FLAT" \
  || fail "the protocol must name what happens when no engine resolves"
ok "no engine CLI is a stated precondition, not a per-story surprise"

echo "the protocol orders dispatch against the pool, and releases on every path"
grep -q 'pool-lane-protocol.md' "$DISPATCH" \
  || fail "the dispatch protocol must defer slot accounting to the pool protocol rather than restating it"
grep -qi 'assign . dispatch . record running . wait . record idle' "$DIS_FLAT" \
  || fail "the dispatch protocol must state its ordering against the pool protocol"
grep -qi 'before branching on what it returned' "$DIS_FLAT" \
  || fail "the dispatch protocol must release the slot before branching on the outcome"
ok "dispatch and slot accounting are ordered and separated"

echo "run-project defaults to detached lanes"
grep -q 'lane-dispatch-protocol.md' "$RUN_PROJECT" \
  || fail "run-project must defer to the shared dispatch protocol"
grep -qi 'detached lane' "$RUN_FLAT" \
  || fail "run-project must say its stories run as detached lanes"
# The old default was a blocking in-parent spawn/wait per story.
grep -qi 'default is inline. a bare ./run-project {project}. uses story-level .spawn_agent' "$RUN_FLAT" \
  && fail "run-project's Rules still advertise blocking spawn_agent as the default"
ok "the story loop dispatches detached, not in-session"

echo "run-project keeps the in-session path as a named fallback"
# Removing it entirely would strand a host with no codex/grok/claude CLI.
grep -qi 'spawn_agent' "$RUN_PROJECT" \
  || fail "run-project dropped the in-session fallback; a host with no engine CLI loses the skill entirely"
grep -qi 'fallback' "$RUN_FLAT" \
  || fail "run-project must name the in-session path as a fallback, not leave it ambiguous"
ok "a host without an engine CLI still has a documented path"

echo "detaching did not drop the return contract or the proof gates"
grep -q 'RETURN CONTRACT: json' "$RUN_PROJECT" \
  || fail "the story return contract was lost in the switch to detached lanes"
grep -q 'INVALID_RETURN_FORMAT' "$RUN_PROJECT" \
  || fail "the malformed-JSON retry path was lost in the switch to detached lanes"
grep -q 'verify-story-deliverables.sh' "$RUN_PROJECT" \
  || fail "the evidence gate was lost in the switch to detached lanes"
grep -q 'conduct-pool.sh assign' "$RUN_PROJECT" \
  || fail "run-project stopped claiming pool slots"
ok "the contract, the retry, the evidence gate and the pool all survived"

echo "ralph mode is detached, and no longer claims otherwise"
grep -qi 'it does not launch a detached subprocess' "$RUN_FLAT" \
  && fail "ralph mode still says it does not detach, which is now false"
ok "ralph mode's own description matches how it dispatches"

echo "conduct defers to the protocol instead of restating it"
grep -q 'lane-dispatch-protocol.md' "$CONDUCT" \
  || fail "conduct must defer to the shared dispatch protocol"
# Two copies of the launch block is the drift shape this file exists to prevent.
launch_copies="$(grep -c 'setsid nohup bash -c' "$CONDUCT")"
[ "$launch_copies" -eq 0 ] \
  || fail "conduct still carries its own copy of the launch block ($launch_copies); the protocol owns it now"
ok "the launch block lives in exactly one place"

echo "both callers name the same lane handle"
for f in "$RUN_FLAT" "$CON_FLAT"; do
  # shellcheck disable=SC2016  # $RUN_DIR is literal text in the skill, not a var
  grep -qi 'basename "\$RUN_DIR"\|run-dir basename\|basename of the run dir' "$f" \
    || grep -q 'lane-dispatch-protocol.md' "${f%.flat}" 2>/dev/null \
    || fail "a caller neither states the lane handle nor defers to the protocol that does"
done
grep -qi 'run-dir basename is the lane.s handle' "$DIS_FLAT" \
  || fail "the protocol must state what gets recorded as the subagent id"
ok "the recorded handle is defined once, in the protocol"

echo "the waiter has a wall-clock deadline, because timeoutSecs is only a warning"
# workflow-runner.mjs prints a repeating TIMEOUT WARNING and explicitly does not
# kill the child, so a waiter looping for CONDUCT_EXIT waits forever on a hung
# lane. Ralph's `blocked: TIMEOUT` contract is unenforceable without this.
# shellcheck disable=SC2016  # literal text in the protocol, not a shell expansion
grep -q '\$D/deadline\|RUN_DIR/deadline' "$DISPATCH" \
  || fail "the waiter has no wall-clock deadline; a hung lane blocks its caller forever"
grep -qi 'does not kill\|not killed' "$DIS_FLAT" \
  || fail "the protocol must say timeoutSecs is soft, or a caller will trust it as a bound"
grep -qi 'the lane is still running' "$DIS_FLAT" \
  || fail "the deadline exit must say the process is still alive"
grep -qi 'stopped cleanly\|confirmed empty\|confirmed gone' "$DIS_FLAT" \
  || fail "the protocol must require a confirmed stop before the slot is retired"
ok "a hung lane is bounded, stopped, and confirmed before its slot is reused"

echo "run-project's timeout flag points at the deadline, not at timeoutSecs"
grep -qi 'not the runner.s .timeoutSecs' "$RUN_FLAT" \
  || fail "run-project must not let --timeout N be read as the runner's soft timeout"
ok "--timeout N is wired to the bound that actually bounds"

echo "the lane tier is a caller-supplied placeholder, not hardcoded"
# The preflight explorer needs `plan`; a hardcoded `exec` silently ran analysis
# on the throughput model.
grep -q 'tier: \\"{tier}\\"' "$DISPATCH" \
  || fail "the protocol hardcodes a tier; the explorer cannot ask for plan"
grep -qi '{tier}. = .plan' "$RUN_FLAT" \
  || fail "run-project's preflight must pass tier plan explicitly"
grep -q '{tier}' "$CONDUCT" \
  || fail "conduct must supply a tier now that the protocol takes one"
ok "every caller names its tier"

echo "run-project's mode flags agree with the detached default"
# --inline predates lanes. Left undefined it reads as "in the parent session".
grep -qi 'story-level Codex sub-agent execution .default.' "$RUN_FLAT" \
  && fail "--inline is still defined as in-session sub-agent execution"
grep -qi 'ralph now runs inline in the active session' "$RUN_FLAT" \
  && fail "the legacy note still claims ralph runs in the active session"
grep -qi 'the name is historical' "$RUN_FLAT" \
  || fail "--inline must say what it now means, or it contradicts Step 3"
ok "the argument parser and the dispatch model describe the same thing"

echo "the deadline survives into the waiter's own process"
# Launch and wait are separate Bash calls. A shell variable set at launch is
# empty in the waiter, and `[ "$(date +%s)" -ge "" ]` errors every iteration —
# an inert guard that reads as a working one.
grep -q 'deadline"' "$DISPATCH" \
  || fail "the deadline is not persisted; the waiter cannot see a launch-time variable"
grep -qi 'waiter is a different process\|separate background call' "$DIS_FLAT" \
  || fail "the protocol must say why the deadline goes on disk"
grep -qi 'refusing to wait unbounded' "$DISPATCH" \
  || fail "a missing deadline file must not degrade to waiting forever"
ok "the deadline is on disk and a missing one is fatal, not ignored"

echo "liveness is a group question, and the protocol says what it cannot see"
# Round 2 asserted a wrapper-group kill here. That remedy was wrong -- the
# engine is spawned detached into its own group -- and the check below replaces
# it. What survives is the in-loop probe and the reason it is not a pid check:
# the wrapper can exit with the runner still working.
grep -q 'pgrep -g' "$DISPATCH" \
  || fail "in-loop liveness must be checked against the group, not the wrapper pid"
grep -qi 'cannot see the engine' "$DIS_FLAT" \
  || fail "the protocol must state what the group probe cannot observe"
ok "the in-loop probe is honest about its blind spot"

echo "the engine roster lives where both callers can reach it"
# shellcheck disable=SC2016  # literal text in the protocol, not a shell expansion
grep -q '| `codex` (default)' "$DISPATCH" \
  || fail "the dispatch protocol references a roster it does not define"
grep -qi 'resolution is deterministic, and happens once' "$DIS_FLAT" \
  || fail "the protocol must give a deterministic selection rule, not just a list"
grep -qi 'reuse it for every lane in that run' "$DIS_FLAT" \
  || fail "the protocol must pin one engine per run"
grep -qi 'resolve the engine once, before the first dispatch' "$RUN_FLAT" \
  || fail "run-project must resolve its engine before the preflight, not per lane"
ok "one engine per run, chosen by a stated rule"

echo "the deadline handler signals the runner, which owns the detached engine"
# workflow-runner.mjs spawns the engine with detached: true, so the engine leads
# its OWN process group. Signalling the wrapper group never reaches it and
# pgrep -g cannot see it, so an empty group proves nothing.
grep -q 'runner.pid' "$DISPATCH" \
  || fail "the launch does not record the runner pid, so nothing can stop the lane cleanly"
grep -qi 'detached: true' "$DIS_FLAT" \
  || fail "the protocol must say why the engine is unreachable from the wrapper group"
grep -qi 'killTree is the only code that holds\|only code that holds the engine' "$DIS_FLAT" \
  || fail "the protocol must say why the runner, not the group, is the thing to signal"
ok "the runner is asked to stop, because only it can reach the engine"

echo "the stop grace does not race the runner's own escalation"
grep -qi 'escalates to SIGKILL after \*\*5 seconds\*\*\|escalates to sigkill after 5 seconds' "$DIS_FLAT" \
  || fail "the protocol must name the runner's own escalation timer it has to outlast"
grep -q 'seq 1 30' "$DISPATCH" \
  || fail "the stop grace must comfortably exceed the runner's 5s escalation"
ok "the grace outlasts the runner rather than racing it"

echo "an unconfirmed stop blocks the recycle instead of authorising it"
grep -qi 'do NOT recycle this slot' "$DISPATCH" \
  || fail "an unconfirmed stop must not read as permission to reuse the slot"
grep -qi 'only a clean stop earns the recycle' "$DIS_FLAT" \
  || fail "the protocol must make the clean-stop precondition explicit"
grep -qi 'only if the lane stopped cleanly' "$RUN_FLAT" \
  || fail "run-project must gate its recycle --force on a confirmed clean stop"
ok "an unknown state stays unknown and stops the run"

echo "the pool protocol releases on process completion, not on validation"
# run-project's one retry re-assigns the same worker; a slot released only after
# the JSON validates sends that retry to exit 4.
POOL_FLAT="$TMP/pool.flat"; flatten "$POOL_PROTO" > "$POOL_FLAT"
grep -qi 'release on process completion, not on result validation' "$POOL_FLAT" \
  || fail "the pool protocol still gates release on a valid reply, contradicting its callers"
grep -qi 'returned garbage' "$POOL_FLAT" \
  || fail "the pool protocol must name a malformed reply as still releasing the slot"
grep -qi 'could not confirm dead' "$POOL_FLAT" \
  || fail "the pool protocol must carve out the unconfirmed-lane exception"
ok "one release ordering, stated in the protocol both callers read"

echo "run dirs cannot collide across sessions or within a second"
# explorer and regression-gate are constant lane ids and story ids repeat, so a
# {caller}-{lane}-$TS path let a second session overwrite the first's brief,
# pids, deadline and log — another tenant's inputs, not just a clobbered log.
grep -q 'mktemp -d' "$DISPATCH" \
  || fail "run dirs are not minted atomically; two launches in one second collide"
# shellcheck disable=SC2016  # literal text in the protocol, not a shell expansion
grep -q 'workflow-runner/\$SID' "$DISPATCH" \
  || fail "run dirs are not session-scoped; two sessions share a path"
grep -qi 'another tenant.s brief' "$DIS_FLAT" \
  || fail "the protocol must name the cross-tenant consequence, not just the collision"
ok "every run dir is session-scoped and atomically unique"

echo "no caller spells its own run-dir path"
# The collision fix landed in the protocol while three call sites still named
# workspace/tmp/workflow-runner/{caller}-{lane}-$TS -- against a $TS that no
# longer existed. A caller-specific path is the drift; the protocol mints it.
for f in "$RUN_PROJECT" "$CONDUCT"; do
  if grep -q 'workspace/tmp/workflow-runner/' "$f"; then
    fail "$(basename "$(dirname "$f")") spells its own run dir; the protocol mints it and this path will drift"
  fi
done
grep -qi 'callers name .{caller}. and .{lane}., never a path' "$DIS_FLAT" \
  || fail "the protocol must forbid caller-supplied paths, not merely define its own"
ok "the run-dir template exists in exactly one place"

echo "conduct releases its slot before verifying and retrying"
# conduct step 3 re-assigns the same worker on failure. Releasing after
# verification sends that retry to exit 4.
CON_REL="$(grep -n 'Release the slot first' "$CONDUCT" | head -1 | cut -d: -f1)"
CON_VER="$(grep -n 'Verify independently' "$CONDUCT" | head -1 | cut -d: -f1)"
CON_RETRY="$(grep -n 'send the errors back to the' "$CONDUCT" | head -1 | cut -d: -f1)"
[ -n "$CON_REL" ] && [ -n "$CON_VER" ] && [ -n "$CON_RETRY" ] \
  || fail "conduct's outcome flow lost its release, verify, or retry step"
[ "$CON_REL" -lt "$CON_VER" ] && [ "$CON_REL" -lt "$CON_RETRY" ] \
  || fail "conduct releases the slot (line $CON_REL) after verify/retry ($CON_VER/$CON_RETRY); the retry gets exit 4"
grep -qi 'the engine runs detached in a group of its own' "$CON_FLAT" \
  || fail "conduct's hung-lane row still recommends a group kill that cannot reach the engine"
ok "conduct's ordering matches the protocol it defers to"

echo "the runner journals the engine's process group, and the protocol reads it"
# CONDUCT_EXIT proves the RUNNER exited, not that the tree is down. If the
# engine's group leader dies on SIGTERM but a descendant ignores it,
# child.on('close') deletes the child and calls onAllChildrenGone immediately,
# retiring the runner before its own 5s SIGKILL escalation ever fires. The
# survivor then outlives the marker. Only the runner can name that group -- it
# spawned it detached -- so it has to write the pgid down.
grep -q "event: 'agent-spawned'" "$RUNNER" \
  || fail "the runner does not journal the spawn; nothing outside it can name the engine's process group"
grep -q "pgid: child.pid" "$RUNNER" \
  || fail "the agent-spawned journal entry carries no pgid, so a supervisor still cannot find the group"
grep -q 'agent-spawned' "$DISPATCH" \
  || fail "the protocol never reads the journalled pgid, so its clean-stop check is still marker-only"
grep -q 'journal.jsonl' "$DISPATCH" \
  || fail "the protocol must say where the pgid is recorded"
grep -qi 'not proof the tree is down\|marker alone is not proof' "$DIS_FLAT" \
  || fail "the protocol must state that the exit marker is not proof of a stopped tree"
ok "the engine's group is recorded at spawn and read back at teardown"

echo "a surviving engine group withholds the recycle"
# The probe has to be able to change the verdict, not merely print. Round 6
# asserted this by line order, when the probe was inline in the deadline
# handler; the probe is now a shared block placed after the branches, so the
# ordering is asserted separately (see the graceful_attempted check below) and
# what is pinned here is the causal link: survivors -> engine_gone=no ->
# unconfirmed -> no recycle.
# shellcheck disable=SC2016  # $epgid is literal text in the protocol, not a shell expansion
grep -q 'pgrep -g "\$epgid" >/dev/null 2>&1 && engine_gone=no' "$DISPATCH" \
  || fail "a surviving engine group must record itself, not just print"
grep -qi 'any outcome with .engine_gone=no.' "$DIS_FLAT" \
  || fail "engine_gone=no must be named as a way into the unconfirmed state"
grep -qi 'only a clean stop earns the recycle' "$DIS_FLAT" \
  || fail "the protocol must make the clean-stop precondition explicit"
grep -qi 'the slot stays .running. and a human decides' "$DIS_FLAT" \
  || fail "a survivor must park the slot rather than release it"
ok "a surviving engine group blocks the recycle"

echo "the lane result is decoded from the runner's result file, not its stdout"
# lane.log is the runner's whole stdout: narration plus JSON.stringify(result).
# A schema-less agent() returns the engine reply as TEXT, so that value is a
# JSON *string* holding the worker's JSON. `jq -e .` on it succeeds and every
# field access then comes back empty -- a story that returned everything reads
# as a story that returned nothing, and the worker-proof gate rejects a worker
# that did run its phases.
grep -q 'agent-1.result.json' "$DISPATCH" \
  || fail "the protocol does not name the result file, so callers fall back to the log"
grep -q "jq -r '.value'" "$DISPATCH" \
  || fail "the protocol must show the envelope being unwrapped before the contract is parsed"
grep -qi 'json .\*\*string\*\*\|json \*\*string\*\*\|is a json string' "$DIS_FLAT" \
  || fail "the protocol must explain why jq -e . on lane.log passes while every field is empty"
grep -qi 'do not read the payload out of .lane.log.' "$DIS_FLAT" \
  || fail "the protocol must forbid the log as a result channel outright"
for f in "$RUN_PROJECT" "$CONDUCT"; do
  grep -q 'agent-1.result.json' "$f" \
    || fail "$(basename "$(dirname "$f")") never names the result file; it will read the log"
done
grep -qi "runner's stdout is the lane's report" "$CON_FLAT" \
  && fail "conduct still points at the runner's stdout for the lane's report"
grep -qi 'not in .lane.log.' "$RUN_FLAT" \
  || fail "run-project's story loop must say the JSON is not in lane.log"
ok "both callers read agent-1.result.json and unwrap it"

echo "a resume mints a fresh run dir instead of reusing the finished one"
# A completed run dir still holds CONDUCT_EXIT= and the old pid files. The new
# child does not truncate lane.log until it is already detached, so a waiter
# armed in between reads the old marker and releases a slot that is still live.
grep -qi 'every dispatch mints a fresh run dir . including a resume' "$DIS_FLAT" \
  || fail "the protocol does not require a fresh run dir on resume"
grep -qi 'handoffs.jsonl' "$DIS_FLAT" \
  || fail "the protocol must say where lane continuity lives once the run dir stops being reused"
grep -qi 'launch into the SAME run directory\|reuse the existing run dir' "$CON_FLAT" \
  && fail "conduct still tells a resume to relaunch into the finished lane's directory"
grep -qi 'mint a fresh one on a resume too' "$CON_FLAT" \
  || fail "conduct's resume branch must state the fresh-run-dir rule, not just omit the old one"
grep -qi 'new run-dir basename against the \*\*same\*\* slot' "$RUN_FLAT" \
  || fail "run-project's resume branch must move the run id while keeping the slot"
ok "a resume reuses the slot, never the directory"

echo "the engine-group confirmation covers every outcome, not just the timeout"
# died/never-started are statements about the WRAPPER. A SIGKILLed wrapper
# cannot take its runner's detached child with it, so releasing on `died`
# without checking the journalled engine pgid starts a replacement worker on
# top of a live engine -- the same defect as the timeout path, on a branch that
# fires more often.
grep -q 'engine_gone' "$DISPATCH" \
  || fail "the protocol has no outcome-independent engine check; only the deadline branch is covered"
grep -qi 'no outcome releases the slot until the engine group is confirmed empty' "$DIS_FLAT" \
  || fail "the protocol must state the confirmation as a precondition of release, not a step in one branch"
grep -qi 'releasing on .died. without it starts a replacement worker on top of a live engine' "$DIS_FLAT" \
  || fail "the protocol must name the died-branch consequence, not just extend the check"
grep -qi 'then run the confirmation below with .graceful_attempted=yes.' "$DIS_FLAT" \
  || fail "the deadline branch must hand off to the shared confirmation rather than keeping its own copy"
# Not a regression for this round -- the previous revision also had exactly one
# copy, inline in the deadline branch. This is the drift guard that keeps the
# generalisation from being undone by someone re-inlining a second copy, which
# is how the two-copies-one-wrong shape got into this file the first time.
DIS_N="$(grep -c 'select(.event=="agent-spawned")|.pgid' "$DISPATCH")"
[ "$DIS_N" -eq 1 ] \
  || fail "the engine-pgid lookup appears $DIS_N times; one copy will drift from the other"
grep -qi 'applies to every outcome, not just the timeout' "$POOL_FLAT" \
  || fail "the pool protocol's carve-out still reads as timeout-only"
ok "one confirmation, applied to every exit path"

echo "run-project does not claim a run that drives itself after the session ends"
# Only the in-flight lane is detached. The waiter, the validation, the slot
# release and the dispatch of story N+1 are all parent-side, so a session that
# ends mid-run finishes one story and stops. Claiming otherwise tells a user to
# close their laptop on a run that will not advance.
grep -qi 'the .story. survives, the .coordinator. does not\|the \*story\* survives, the \*coordinator\* does not' "$RUN_FLAT" \
  || fail "run-project must distinguish the surviving story from the parent-side coordinator"
grep -qi 'resumable, not self-driving\|resumable, not \*self-driving\*' "$RUN_FLAT" \
  || fail "run-project must name what the guarantee actually is"
grep -qi 'does not auto-advance to story N+1 unattended' "$RUN_FLAT" \
  || fail "ralph mode must say the loop stops with its session, not merely omit it"
grep -qi 'do not tell a user their run will finish on its own' "$RUN_FLAT" \
  || fail "the skill must forbid the overclaim to the user, not just avoid making it itself"
grep -qi 'can pick the run back up . nothing picks itself back up' "$RUN_FLAT" \
  || fail "the recovery note still reads as automatic resumption"
grep -qi 'so a run survives session compaction' "$RUN_FLAT" \
  && fail "the frontmatter description still promises whole-run survival"
ok "the survivability claim matches the mechanism"

echo "the engine confirmation observes first and only forces after a refusal"
# The previous revision generalised the check by running it BEFORE the branch
# handling and SIGKILLing on sight -- which meant the deadline branch never got
# to ask the runner politely, and a timed-out worker was torn down mid-write.
# The runner's killTree is the only graceful path; force is what you do after a
# request is refused, not instead of making one.
grep -q 'graceful_attempted' "$DISPATCH" \
  || fail "the confirmation kills unconditionally; the deadline branch's graceful path is unreachable"
# shellcheck disable=SC2016  # literal protocol text, not a shell expansion
grep -q 'if \[ "\$graceful_attempted" = yes \]; then' "$DISPATCH" \
  || fail "the SIGKILL is not gated on a prior graceful attempt"
grep -qi 'observation first, force only after a refused request' "$DIS_FLAT" \
  || fail "the protocol must state the ordering rule, not just implement it"
grep -qi 'run this last, on every outcome' "$DIS_FLAT" \
  || fail "the confirmation must be ordered after branch teardown, not before it"
grep -qi 'there was no request to refuse, so a survivor is observed and reported, never killed' "$DIS_FLAT" \
  || fail "the non-deadline branches must not authorise a kill"
# Ordering in the file, not just in the prose: the branch teardown has to come
# before the confirmation, or a reader runs them in the order they are written.
# shellcheck disable=SC2016  # literal protocol text, not a shell expansion
DIS_TERM="$(grep -n 'kill -TERM "\$(cat "\$D/runner.pid")"' "$DISPATCH" | head -1 | cut -d: -f1)"
DIS_CONF="$(grep -n '^graceful_attempted=' "$DISPATCH" | head -1 | cut -d: -f1)"
[ -n "$DIS_TERM" ] && [ -n "$DIS_CONF" ] && [ "$DIS_TERM" -lt "$DIS_CONF" ] \
  || fail "the confirmation block (line ${DIS_CONF:-?}) is written before the runner is signalled (line ${DIS_TERM:-?})"
ok "the runner is asked first; force is gated on its refusal"

echo "args.json is built by a JSON encoder, not by printf"
# A double quote or backslash anywhere in the HQ install path or the target
# work dir makes printf '%s' emit invalid JSON, and the runner then fails on
# --args before the lane exists -- in a log nobody is watching yet.
grep -q 'jq -n --arg brief' "$DISPATCH" \
  || fail "args.json is not built with an encoder; a quote in a path breaks the launch"
grep -q "printf '{\"brief\"" "$DISPATCH" \
  && fail "the printf construction of args.json is still present"
grep -qi 'build .args.json. with an encoder, not with .printf.' "$DIS_FLAT" \
  || fail "the protocol must say why, so the shorter printf form does not come back"
ok "paths with shell-hostile characters cannot break the launch"

echo "cross-session recovery uses the originating session id"
# conduct-pool.sh resolves the session from the environment and run dirs live
# under $SID, so a NEW session sees an empty pool while the old lanes are still
# running -- and re-dispatches a story whose lane is already committing.
grep -q 'session_id' "$RUN_PROJECT" \
  || fail "run-project never persists the session id, so a later session cannot find its own lanes"
grep -q -- '--session-id' "$RUN_PROJECT" \
  || fail "the recovery path does not pass the originating session id to conduct-pool.sh"
grep -qi 'never overwrite it on a resume' "$RUN_FLAT" \
  || fail "a resume that rewrites session_id loses the handle to the live lanes"
grep -qi 'do not re-dispatch a story whose lane is still up' "$RUN_FLAT" \
  || fail "recovery must not restart a story that is still mid-flight"
grep -qi 'record the story.s run dir on the story entry as you dispatch it' "$RUN_FLAT" \
  || fail "run dirs recorded only on return are absent in exactly the case they are needed"
grep -qi 'session inspecting the same project sees an empty pool' "$DIS_FLAT" \
  || fail "the protocol must state that pool and run dirs are session-keyed"
ok "a later session can find, and will not duplicate, the original lanes"

echo "the nested launch body interpolates nothing"
# The body used to be a double-quoted string with $PWD, $RUN_DIR and $SID
# substituted into single-quoted values inside it. An apostrophe in the HQ
# checkout path -- the one value here a user controls -- closes those quotes
# early and the lane dies before it starts, in a log nobody is watching yet.
grep -q "setsid nohup bash -c '" "$DISPATCH" \
  || fail "the nested body is not single-quoted; path text is still parsed as shell"
# shellcheck disable=SC2016  # literal protocol text, not a shell expansion
grep -q 'export LANE_RUN_DIR_ABS="\$PWD/\$RUN_DIR"' "$DISPATCH" \
  || fail "the absolute run dir is not passed through the environment"
grep -q "\$PWD/\$RUN_DIR'" "$DISPATCH" \
  && fail "the HQ path is still interpolated into a single-quoted value inside the body"
grep -qi 'the nested body is single-quoted and interpolates nothing' "$DIS_FLAT" \
  || fail "the protocol must state the rule, or the shorter interpolated form comes back"
ok "an apostrophe in the install path cannot break a launch"

echo "the owning session id survives a resumed dispatch"
# Recomputing $SID at dispatch undoes the recovery fix: the lane exports the new
# session, mints its run dir there, and an unqualified record writes to a pool
# that never assigned the slot -- a live lane untracked, the original slot stuck
# claimed.
grep -qi 'is the run.s owner, not .whoever is dispatching.' "$DIS_FLAT" \
  || fail "the protocol still reads as though SID is always the current session"
grep -qi 'one session id per run, chosen once, end to end' "$DIS_FLAT" \
  || fail "the protocol must state the invariant, not just the exception"
grep -qi 'or the run.s recorded owner' "$DISPATCH" \
  || fail "the mint site must admit the owner-id case at the point of use"
grep -qi 'session-id.* when .*SID. is a run.s recorded owner' "$DIS_FLAT" \
  || fail "record must be qualified when the owner is not the current session"
ok "a resumed dispatch stays in the pool that owns the slot"

echo "every caller withholds release on an unconfirmed engine, not just on a deadline"
# The shared protocol confirms the engine group after EVERY outcome, but both
# callers still described the carve-out as timeout-only -- so a coordinator
# could mark a `died` lane idle and retry on top of a live engine.
grep -qi 'on any outcome, not only a deadline' "$CON_FLAT" \
  || fail "conduct's release exception is still scoped to the deadline path"
grep -qi 'engine_gone=no' "$CON_FLAT" \
  || fail "conduct must name the confirmation's own signal, not paraphrase it"
grep -qi 'engine_gone=yes' "$RUN_FLAT" \
  || fail "run-project's recycle gate does not consult the engine confirmation"
grep -qi 'runs on every outcome, not just this one' "$RUN_FLAT" \
  || fail "run-project still reads as though the confirmation is timeout-only"
ok "both callers gate release on the confirmation, on every path"

echo "the lane launch snippet is valid shell, outside and inside"
# The launch block is a quoting minefield: a detached `setsid bash -c "..."`
# whose body itself contains a single-quoted --eval string. Two separate parses
# happen, and only the outer one is visible to `bash -n` on the whole snippet —
# an unbalanced quote INSIDE the body is just a character to the outer shell and
# sails through. It fails later, at dispatch, in a detached process whose output
# goes to a log nobody is watching yet. So check both levels. These two checks
# used to live in conduct-worker-selection.test.sh; they followed the block here.
snippet="$TMP/launch.sh"
# The run dir is minted in §3 and the launch is §4, with prose between, so
# extract §4 and supply §3's outputs. §4 is the quoting-critical part.
# shellcheck disable=SC2016  # deliberately unexpanded: this line is written into the snippet
{ echo 'RUN_DIR="$TMP/run"; mkdir -p "$RUN_DIR"; SID=s1'; } > "$snippet"
# shellcheck disable=SC2016  # the $ is part of the literal anchor in the protocol
sed -n "/^LANE_TIMEOUT=/,/^' > \/dev\/null 2>&1 < \/dev\/null &/p" "$DISPATCH" \
  | sed -e 's/{engine}/codex/g' \
        -e 's/{lane}/demo/g' \
        -e 's/{caller}/conduct/g' \
        -e 's/{the brief}/BRIEF/' \
        -e 's|{absolute work dir}|/tmp|' \
        -e 's/{worker max_runtime in seconds, else 900}/900/' \
  >> "$snippet"
[ -s "$snippet" ] || fail "could not extract the launch snippet — its anchors moved"
grep -q 'LANE_TIMEOUT' "$snippet" || fail "the launch no longer honours the caller's timeout"
grep -q 'HQ_SESSION_ID' "$snippet" || fail "the launch no longer exports the session id"
grep -q 'runner.pid' "$snippet" || fail "the launch no longer records the runner pid"
bash -n "$snippet" || fail "the lane launch snippet is not valid bash (outer)"
ok "the launch snippet parses and carries the timeout and session id"

echo "the detached bash -c body is valid shell in its own right"
inner="$TMP/inner.sh"
sed -n "/^setsid nohup bash -c '$/,/^' > \/dev\/null/p" "$snippet" \
  | sed -e '1d' -e '$d' \
  > "$inner"
[ -s "$inner" ] || fail "could not extract the bash -c body — the launch block's shape changed"
grep -q 'workflow-runner.mjs' "$inner" || fail "the bash -c body no longer launches the runner"
bash -n "$inner" || fail "the detached bash -c body is not valid bash"
ok "the inner script parses too"

echo
echo "orchestrator-skills-dispatch-lanes.test.sh: $PASS checks passed"
