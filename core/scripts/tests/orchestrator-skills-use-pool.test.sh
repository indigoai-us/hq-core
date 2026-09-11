#!/usr/bin/env bash
# orchestrator-skills-use-pool.test.sh — pins /execute-task and /run-project to
# the session worker pool.
#
# The hard policy ralph-orchestrator-context-discipline now requires every
# orchestrator slot to be claimed through conduct-pool.sh and reused across
# stories. A policy that says that while the shipped skills still spawn a fresh
# child per phase or per story is worse than either alone: an agent reads both
# and cannot satisfy them at once. These checks are the mechanical half of that
# promise.
#
# They pull two ways on purpose. Wiring the pool in must not drop the JSON
# return contract, the evidence gate, or the inline codex-reviewer path; and the
# spawn-per-story language must not creep back in.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILLS="${HQ_ORCH_SKILLS_DIR:-$ROOT/.claude/skills}"
EXEC_TASK="$SKILLS/execute-task/SKILL.md"
RUN_PROJECT="$SKILLS/run-project/SKILL.md"
PROTOCOL="$SKILLS/_shared/pool-lane-protocol.md"
CONDUCT="$SKILLS/conduct/SKILL.md"
POOL="$ROOT/core/scripts/conduct-pool.sh"

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok — $1"; }

# Prose in these skills is hard-wrapped, so a phrase that reads as one sentence
# can straddle a newline. Match prose against a whitespace-collapsed copy so a
# reflow does not silently turn a real check into a passing no-op.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
flatten() { tr '\n' ' ' < "$1" | tr -s ' '; }

for f in "$EXEC_TASK" "$RUN_PROJECT" "$PROTOCOL" "$CONDUCT"; do
  [ -f "$f" ] || fail "missing $f"
done

flatten "$EXEC_TASK" > "$TMP/execute-task.flat"
flatten "$RUN_PROJECT" > "$TMP/run-project.flat"
flatten "$PROTOCOL" > "$TMP/protocol.flat"
EXEC_FLAT="$TMP/execute-task.flat"
RUN_FLAT="$TMP/run-project.flat"
PROTO_FLAT="$TMP/protocol.flat"

echo "pool helper: the script both skills now depend on actually exists"
[ -f "$POOL" ] || fail "missing $POOL — the skills reference a helper that does not ship"
for cmd in assign record recycle; do
  grep -q "cmd_$cmd" "$POOL" || fail "conduct-pool.sh has no '$cmd' command, but the skills call it"
done
ok "conduct-pool.sh ships with assign, record and recycle"

echo "execute-task: a phase claims a lane before it dispatches"
grep -q 'conduct-pool.sh assign' "$EXEC_TASK" \
  || fail "step 6c must claim the worker's slot with conduct-pool.sh assign"
grep -q -- '--worker-id "{worker.id}"' "$EXEC_TASK" \
  || fail "a phase must claim the bare worker id"
grep -qi 'On .resume., send only the phase ask' "$EXEC_FLAT" \
  || fail "6c must handle the resume answer, not only spawn"
ok "6c assigns first and branches on spawn vs resume"

echo "protocol: the refusal exit codes are handled, not ignored"
# assign changes nothing on 3 or 4. A caller that does not read them spawns past
# the cap or relaunches into a run directory a live process still owns.
grep -q 'exit 3' "$PROTOCOL" || fail "the protocol must say what to do when the pool is at cap (exit 3)"
grep -q 'exit 4' "$PROTOCOL" || fail "the protocol must say what to do when the lane is running (exit 4)"
grep -qi 'relaunch into a run directory a working process still owns' "$PROTO_FLAT" \
  || fail "the protocol must forbid resuming a running lane outright"
grep -qi 'Dispatching past them is exactly how a run exceeds' "$PROTO_FLAT" \
  || fail "the protocol must name the failure the exit codes prevent"
ok "exit 3 and exit 4 both have a documented, non-dispatching response"

echo "protocol: lanes are released, so the next claim can resume them"
grep -q 'conduct-pool.sh record' "$PROTOCOL" \
  || fail "the protocol must record lane state back to the pool"
grep -q -- '--status running' "$PROTOCOL" || fail "the lane must be marked running around the blocking call"
grep -q -- '--status idle' "$PROTOCOL" || fail "the lane must be released to idle once the work returns"
grep -qi 'never resumable' "$PROTO_FLAT" \
  || fail "the protocol must say why a lane left running stalls the run"
ok "running/idle are both recorded and the stall mode is named"

echo "protocol: the no-resume runtime has a real fallback, not a pretence"
# Claude Code's Task and Codex spawn_agent both start a new agent every time.
grep -q 'handoffs.jsonl' "$PROTOCOL" \
  || fail "the fallback must carry lane continuity on disk"
grep -qi 'Do not pretend otherwise' "$PROTO_FLAT" \
  || fail "the protocol must say plainly that faking a resume is not allowed"
grep -qi 'cap counts lanes, not restarts' "$PROTO_FLAT" \
  || fail "a fallback restart must not be described as consuming a second slot"
ok "the fallback restarts the lane on disk and keeps the same slot"

echo "execute-task: spawn-per-worker language is gone from the rules"
if grep -qE '^- \*\*Fresh context per worker\*\*' "$EXEC_TASK"; then
  fail "the Rules block still mandates fresh context per worker — contradicts the pool"
fi
grep -qi 'One pooled lane per worker' "$EXEC_FLAT" \
  || fail "the Rules block must state the pooled-lane rule that replaced it"
ok "the Rules block describes one pooled lane per worker"

echo "execute-task: the inline codex-reviewer path is untouched and slot-free"
grep -q 'codex review --uncommitted' "$EXEC_TASK" \
  || fail "6c.5 must still run the codex review inline via CLI"
grep -qi 'no pool slot' "$EXEC_FLAT" \
  || fail "6c.5 runs in the parent and must be stated as taking no slot"
ok "codex-reviewer still runs inline in the parent and claims nothing"

echo "run-project: the story loop claims a lane instead of spawning one per story"
if grep -q 'Spawn exactly one story worker' "$RUN_FLAT"; then
  fail "step 3b still spawns exactly one story worker per story"
fi
grep -q 'conduct-pool.sh assign' "$RUN_PROJECT" \
  || fail "step 3b must claim the story worker's lane from the pool"
grep -qi 'serialize' "$RUN_FLAT" \
  || fail "3b must say two stories on the same worker id share one lane"
ok "3b assigns a lane and serializes same-worker stories on it"

echo "run-project: explorer and regression gate are named slots too"
grep -qi 'named pool slot' "$RUN_FLAT" \
  || fail "the preflight explorer must be a named slot, not a throwaway"
grep -qi 'regression-gate pool slot' "$RUN_FLAT" \
  || fail "the regression gate must run in its own reused slot"
ok "preflight explorer and regression gate both resume"

echo "run-project: the budget guardrails state a ceiling that ignores story count"
if grep -q 'one story worker per story' "$RUN_FLAT"; then
  fail "the budget guardrails still promise one story worker per story"
fi
if grep -q 'one worker per story, dispatched in the same batch' "$RUN_FLAT"; then
  fail "the swarming bullet still dispatches an unbounded worker per story"
fi
grep -q 'CONDUCT_POOL_CAP' "$RUN_PROJECT" \
  || fail "the guardrails must name the cap variable"
grep -qi 'does not move with the story count' "$RUN_FLAT" \
  || fail "the guardrails must say the ceiling is independent of the story count"
grep -qi 'only up to the concurrent-story limit above' "$RUN_FLAT" \
  || fail "swarming must be bounded by the concurrent-story limit, not left open-ended"
ok "the ceiling is CONDUCT_POOL_CAP and swarming respects it"

echo "run-project: frontmatter advertises the pool, and interactive stays slot-free"
head -6 "$RUN_PROJECT" | grep -q 'CONDUCT_POOL_CAP' \
  || fail "the description must state the worst-case cap so a caller sees it before loading the skill"
head -6 "$RUN_PROJECT" | grep -qi 'takes no pool slots' \
  || fail "the description must say interactive mode claims nothing"
grep -q 'Interactive mode is parent-driven' "$RUN_PROJECT" \
  || fail "the interactive path must remain parent-driven and unchanged"
ok "frontmatter names the cap; interactive mode is untouched"

echo "run-project: the JSON return path the policy exists for is intact"
for needle in \
  'RETURN CONTRACT: json' \
  'jq -e' \
  'INVALID_RETURN_FORMAT' \
  'verify-story-deliverables.sh' \
  'workers_run'
do
  grep -q -- "$needle" "$RUN_PROJECT" || fail "wiring the pool in dropped '$needle'"
done
ok "return contract, retry gate, worker proof and evidence gate all survive"

echo "both skills defer to one protocol instead of restating it"
# Every drift between these two descriptions so far has meant one of them was
# wrong, so the checks below hold the protocol, not two copies of it.
for f in "$EXEC_TASK" "$RUN_PROJECT"; do
  grep -q '_shared/pool-lane-protocol.md' "$f" \
    || fail "$(basename "$(dirname "$f")") does not point at the shared lane protocol"
done
ok "execute-task and run-project both reference the shared protocol"

echo "protocol: lane continuity is scoped to the session, not the project slug"
# A project slug is not unique across companies, and a project-keyed file
# outlives the session that wrote it. Either way the lane reads someone else's
# history as its own and skips live work.
for f in "$PROTOCOL" "$EXEC_TASK" "$RUN_PROJECT"; do
  if grep -q 'workspace/orchestrator/{project}/pool/' "$f"; then
    fail "$(basename "$f") still keys the slot directory by project slug — collides across companies and sessions"
  fi
done
# shellcheck disable=SC2016  # matching the literal $SID the protocol writes, not expanding it
grep -q 'workspace/sessions/\$SID/pool/' "$PROTOCOL" \
  || fail "the slot directory must live under the resolved session id"
grep -q 'hq-session.sh current' "$PROTOCOL" \
  || fail "the protocol must resolve the session id rather than assume one"
grep -q 'owner.json' "$PROTOCOL" \
  || fail "lane continuity must carry an ownership stamp"
grep -qi 'after .assign. and before the spawn/resume split' "$PROTO_FLAT" \
  || fail "the ownership check must run before the dispatch branch, or a resume-capable runtime skips it"
# mkdir must precede every read/write of the slot dir: assign creates a pool
# entry in meta.yaml and nothing on disk, so the first use has no directory.
# Scope the ordering check to section 3 — earlier sections mention owner.json
# while explaining recycling, and that is not the access this guards.
sec3="$(grep -n '^## 3\. Validate ownership' "$PROTOCOL" | head -1 | cut -d: -f1)"
[ -n "$sec3" ] || fail "the protocol lost its ownership-validation section"
mk_line="$(awk -v s="$sec3" 'NR>s && /mkdir -p "workspace\/sessions/ {print NR; exit}' "$PROTOCOL")"
own_line="$(awk -v s="$sec3" 'NR>s && /owner\.json/ {print NR; exit}' "$PROTOCOL")"
disp_line="$(grep -n '^## 5\. Dispatch' "$PROTOCOL" | head -1 | cut -d: -f1)"
[ -n "$mk_line" ] && [ -n "$own_line" ] && [ "$mk_line" -lt "$own_line" ] \
  || fail "mkdir (line ${mk_line:-?}) must precede any owner.json access (line ${own_line:-?}) — the slot dir does not exist on first use"
[ -n "$disp_line" ] && [ "$own_line" -lt "$disp_line" ] \
  || fail "the owner.json check (line ${own_line:-?}) must precede dispatch (line ${disp_line:-?})"
grep -qi 'cancel --worker-id' "$PROTO_FLAT" \
  || fail "an ownership mismatch must retire the slot so it cannot be resumed into"
# assign marks a new slot running before anything is dispatched, so the reset
# cannot go through recycle — that refuses a running lane and the ownership
# reset would have no way to complete.
grep -qi 'Use .cancel., not .recycle.' "$PROTO_FLAT" \
  || fail "the ownership reset must use cancel; recycle refuses the running slot assign just created"
grep -q 'cmd_cancel' "$POOL" \
  || fail "conduct-pool.sh must implement the cancel verb the protocol depends on"
grep -qi 'Delete .{slot dir}/handoffs.jsonl' "$PROTO_FLAT" \
  || fail "an ownership mismatch must reinitialise the handoff file, not just decline to read it"
grep -qi 'appends in .6 are unconditional' "$PROTO_FLAT" \
  || fail "the protocol must record why declining to read is not enough — the append happens regardless"
ok "slot dirs are created first, session-scoped, checked before either dispatch path, and reinitialised on mismatch"

echo "run-project: its constant-id lanes are ownership-checked too"
# explorer and regression-gate are the same id for every project and company, so
# they are the lanes most likely to hand one tenant'"'"'s context to another.
grep -qi 'not optional here just because the id is a constant' "$RUN_FLAT" \
  || fail "the explorer lane must be ownership-checked despite its constant id"
grep -qi 'another company.s repo list' "$RUN_FLAT" \
  || fail "the regression-gate lane must be ownership-checked despite its constant id"
ok "explorer and regression-gate are validated before reuse, not just the story lanes"

echo "run-project: the resume branch is executable, not a dangling instruction"
# assign has already marked the slot running by the time resume comes back. A
# coordinator that cannot act on it leaves the lane stuck and every later claim
# for that worker exits 4.
grep -qi 'has no resume primitive' "$RUN_FLAT" \
  || fail "run-project must say plainly that spawn_agent cannot resume"
grep -q 'handoffs.jsonl' "$RUN_PROJECT" \
  || fail "run-project must define the disk-backed restart, not just point at resume"
grep -qi 'leaves the lane stuck there' "$RUN_FLAT" \
  || fail "run-project must name what happens if the resume branch is skipped"
ok "the coordinator resume branch has a concrete, executable fallback"

echo "orchestrators: a story coordinator cannot hold the lane its own phase needs"
# The wrapper runs /execute-task; the phases inside it claim the bare worker id.
# A wrapper holding that same id sends its own phase to exit 4 and waits on a
# lane it is itself holding. Nothing in the pool can break that.
grep -q 'story:{worker-id}' "$RUN_PROJECT" \
  || fail "run-project must claim coordinator lanes in the story: namespace"
# conduct-pool.sh restricts ids to [A-Za-z0-9._:-]; a slash delimiter is rejected
# outright, so the coordinator lane is never claimed and the loop cannot start.
# The skill may still *name* story/backend-dev as the rejected form; what it must
# not do is hand one to assign or template one into an id.
if grep -qE -- '--worker-id "story/|story/\{worker-id\}' "$RUN_PROJECT"; then
  fail "run-project claims a slash-delimited coordinator id the pool rejects — assign would exit 1"
fi
grep -qi 'exits 1 and no coordinator lane is claimed' "$RUN_FLAT" \
  || fail "run-project must record that the slash form fails closed, so nobody reintroduces it"
printf '%s\n' 'story:probe' | grep -qE '^[A-Za-z0-9._:-]+$' \
  || fail "the namespace delimiter must satisfy conduct-pool.sh's id charset"
grep -q 'A-Za-z0-9._:-' "$POOL" \
  || fail "conduct-pool.sh no longer documents the id charset this depends on"
if grep -qE 'assign \\?$' "$RUN_PROJECT" && grep -A2 'conduct-pool.sh assign' "$RUN_PROJECT" | grep -q -- '--worker-id "{worker-id}"'; then
  fail "run-project still claims the bare worker id for the story coordinator"
fi
grep -qi 'waiting for a lane the wrapper itself is' "$RUN_FLAT" \
  || fail "run-project must record why the namespace exists, not just that it does"
grep -q 'A-Za-z0-9._:-' "$PROTOCOL" \
  || fail "the protocol must name the id charset the namespace depends on"
grep -qi 'A coordinator must never claim the bare worker id' "$PROTO_FLAT" \
  || fail "the protocol must state that phase lanes use the bare id and coordinators do not"
ok "coordinator and phase lanes live in separate namespaces, with the reason recorded"

echo "run-project: concurrency leaves room for the phase lanes coordinators need"
# Coordinators hold a slot while waiting on a phase lane. Fill the pool with
# coordinators and every one of them blocks on exit 3 with nothing left running
# that could release a slot.
grep -q 'CONDUCT_POOL_CAP - 2) / 2' "$RUN_PROJECT" \
  || fail "the concurrent-story limit must reserve headroom for phase lanes"
grep -q 'CONDUCT_POOL_CAP - 2) / 2' "$PROTOCOL" \
  || fail "the protocol must carry the same nesting budget the skill cites"
grep -qi '3 at the default cap of 8' "$RUN_FLAT" \
  || fail "state the concrete default so a reader does not have to do the arithmetic"
grep -qi 'exit 3 for everyone' "$RUN_FLAT" \
  || fail "the guardrail must name the deadlock it prevents"
ok "concurrent stories are capped so every coordinator can still claim a phase lane"

echo "conduct: its full-pool guidance matches the hardened helper"
# /conduct is a third caller of the same helper. It advertised an unforced
# recycle as the recovery at exit 3, which now exits 5 deterministically.
flatten "$CONDUCT" > "$TMP/conduct.flat"
if grep -qE 'offer to wait or to retire one with' "$TMP/conduct.flat"; then
  fail "/conduct still advertises an unforced recycle at a full pool — that exits 5 now"
fi
grep -qi 'refuses a running lane with exit 5' "$TMP/conduct.flat" \
  || fail "/conduct must say why recycle is not the exit-3 recovery"
grep -q 'cancel --worker-id' "$CONDUCT" \
  || fail "/conduct must offer cancel for a claim it never launched"
ok "/conduct offers waiting, --force after a confirmed stop, and cancel for an undispatched claim"

echo "protocol: recycling a running lane is refused, and clears the lane's history"
# recycle frees a pool entry; it cannot stop a process. The helper enforces this
# with exit 5 — the protocol must not tell callers to reach for it at exit 3.
grep -qi 'refuses a running lane with exit 5' "$PROTO_FLAT" \
  || fail "the protocol must state that recycle refuses a running lane"
grep -q 'EXIT_LANE_RUNNING=5' "$POOL" \
  || fail "conduct-pool.sh must define the refusal exit code the protocol cites"
grep -q 'purge_slot_dir' "$POOL" \
  || fail "conduct-pool.sh must clear a retired lane's persisted history"
grep -qi 'clear the slot.s .handoffs.jsonl. and .owner.json' "$PROTO_FLAT" \
  || fail "the protocol must state that retiring a slot discards the lane's history"
grep -qi 'grows without bound across recycles' "$PROTO_FLAT" \
  || fail "the protocol must name what leaving the history behind costs"
if grep -qi 'retire one deliberately with .recycle --worker-id <id>. and say which' "$PROTO_FLAT"; then
  fail "the exit-3 row still sends callers to recycle, which now refuses a running lane"
fi
ok "recycle refuses running lanes and discards history, in both the helper and the protocol"

echo "protocol: the nesting budget survives a small CONDUCT_POOL_CAP"
# conduct-pool.sh accepts any positive cap. The bare (CAP-2)/2 is 0 at a cap of
# 2 or 3, which would permit no coordinator and stall before the first story.
grep -q 'max(1, (CONDUCT_POOL_CAP - 2) / 2)' "$PROTOCOL" \
  || fail "the coordinator budget must be clamped to at least one"
grep -qi 'yields .*0.* at a cap of 2 or 3' "$PROTO_FLAT" \
  || fail "the protocol must name the caps where the bare formula breaks"
grep -qi 'cap of .*1.* cannot host a coordinator and its phase' "$PROTO_FLAT" \
  || fail "the protocol must say a cap of 1 cannot nest at all"
grep -q 'max(1, (CONDUCT_POOL_CAP - 2) / 2)' "$RUN_PROJECT" \
  || fail "run-project must cite the clamped budget, not the bare formula"
ok "small caps clamp to one serial coordinator; a cap of 1 stops rather than improvises"

echo "every ownership-reset summary uses cancel, not recycle"
# assign grants a slot as `claimed`, so `recycle` is the wrong verb here and the
# protocol switching alone left its consumers contradicting it.
for f in "$PROTOCOL" "$EXEC_TASK" "$RUN_PROJECT"; do
  flat="$TMP/$(basename "$(dirname "$f")").reset.flat"
  flatten "$f" > "$flat"
  grep -qi 'cancel' "$flat" \
    || fail "$(basename "$f") does not mention cancel in its ownership reset"
  if grep -qiE 'mismatch: recycle|recycle, clear|recycle the slot, delete' "$flat"; then
    fail "$(basename "$f") still tells the ownership reset to recycle a claimed slot"
  fi
done
grep -q 'claimed' "$POOL" || fail "conduct-pool.sh must model the claimed state cancel keys on"
flatten "$POOL" > "$TMP/pool.flat"
grep -qi 'An empty subagent_id would' "$TMP/pool.flat" \
  || fail "the helper must record why cancel keys on status rather than an empty subagent_id"
ok "protocol and both skills route the reset through cancel"

echo "conduct lanes are namespaced away from phase lanes"
# /conduct stores a workflow-runner run directory as subagent_id; /execute-task
# stores a Task/spawn_agent handle. Sharing the bare id hands one to the wrong
# adapter, and /conduct lanes carry no owner.json stamp.
grep -q 'conduct:{worker}' "$CONDUCT" \
  || fail "/conduct must claim its lanes in the conduct: namespace"
if grep -qE -- '--worker-id "\{worker\}"' "$CONDUCT"; then
  fail "/conduct still claims a bare worker id, which collides with execute-task phase lanes"
fi
grep -q 'conduct:{worker-id}' "$PROTOCOL" \
  || fail "the protocol's namespace table must list the conduct lanes"
grep -qi 'hand a run-directory name to a runtime expecting a' "$PROTO_FLAT" \
  || fail "the protocol must record why conduct lanes cannot be shared"
ok "conduct, story-coordinator and phase lanes occupy three separate namespaces"

echo "the dispatch sequence is executable on both runtimes"
# Codex hands back an id between spawn_agent and wait_agent; Claude Code's Task
# dispatches and blocks in one call. A sequence that says "record running, then
# dispatch" is impossible on the first and leaves live work marked `claimed` —
# and therefore cancellable — on the second.
grep -qi 'record first with the literal .pending. as the id' "$PROTO_FLAT" \
  || fail "the protocol must give the blocking runtime an executable ordering"
grep -qi 'would leave live work marked .claimed. for its whole duration' "$PROTO_FLAT" \
  || fail "the protocol must say why recording after the wait is wrong"
grep -q -- '--subagent-id pending --status running' "$EXEC_TASK" \
  || fail "execute-task's Claude path must mark the lane running before Task blocks"
# The Codex path must record between the spawn and the wait, not after it.
# Scope to step 6c — wait_agent is also named in the Runtime Adapter section.
sec6c="$(grep -n "^#### 6c\. Claim the Worker's Lane" "$EXEC_TASK" | head -1 | cut -d: -f1)"
[ -n "$sec6c" ] || fail "execute-task lost its 6c dispatch section"
sp="$(awk -v s="$sec6c" 'NR>s && /wait_agent\(\.\.\.\)/ {print NR; exit}' "$EXEC_TASK")"
rec="$(awk -v s="$sec6c" 'NR>s && /--subagent-id "\{agent id\}" --status running/ {print NR; exit}' "$EXEC_TASK")"
[ -n "$sp" ] && [ -n "$rec" ] && [ "$rec" -lt "$sp" ] \
  || fail "execute-task must record running (line ${rec:-?}) before wait_agent blocks (line ${sp:-?})"
grep -qi 'never after the wait' "$RUN_FLAT" \
  || fail "run-project must carry the same ordering for its coordinator lanes"
ok "running is recorded before anything blocks, on both runtimes"

echo "retirement cannot be asserted through record"
# record --status recycled skipped both the running-lane guard and the purge.
if grep -q 'running|idle|recycled)' "$POOL"; then
  fail "record still accepts --status recycled, which routes around the retirement guards"
fi
grep -qi 'record. does NOT accept .--status recycled' "$TMP/pool.flat" \
  || fail "the helper must document that retirement is not a status you can assert"
ok "recycled is not a status record will write"

echo "both skills: the fanout budget is published, per subagent-fanout-budget"
# The policy requires a command's published spec to state its typical and
# worst-case subagent count. A pooled skill's count is set by the cap, so both
# numbers have to survive edits to the story loop.
for f in "$EXEC_TASK" "$RUN_PROJECT"; do
  head -20 "$f" | grep -qi 'Live children' \
    || fail "$(basename "$(dirname "$f")") does not state its live-child count near the top of file"
  head -20 "$f" | grep -q 'CONDUCT_POOL_CAP' \
    || fail "$(basename "$(dirname "$f")") states a typical count but not the worst case"
done
grep -qi 'not by the number of stories' "$RUN_FLAT" \
  || fail "run-project must say the count is independent of the story count"
ok "typical and worst-case live children are published in both skills"

echo "both skills: the lane is released on every return path, not only on success"
# Releasing only under "If success" left a failed phase's lane marked running.
# Debugger recovery, the one malformed-JSON retry, and the next phase all call
# assign again, so each of them hit exit 4 waiting on a sub-agent that had
# already exited. Release is a fact about the sub-agent, not a verdict on it.
exec_6d="$(grep -n '^#### 6d\. Process Worker Output' "$EXEC_TASK" | head -1 | cut -d: -f1)"
[ -n "$exec_6d" ] || fail "execute-task no longer has a 6d section to release the lane in"
exec_idle="$(awk -v s="$exec_6d" 'NR>s && /--status idle/ {print NR; exit}' "$EXEC_TASK")"
exec_fail="$(awk -v s="$exec_6d" 'NR>s && /\*\*If back pressure failed/ {print NR; exit}' "$EXEC_TASK")"
[ -n "$exec_idle" ] && [ -n "$exec_fail" ] \
  || fail "execute-task 6d must both release the lane and branch on back pressure"
[ "$exec_idle" -lt "$exec_fail" ] \
  || fail "execute-task releases the lane after branching (line $exec_idle > $exec_fail); a failed phase strands its slot running and the retry gets exit 4"
grep -qi 'branching on success or failure' "$EXEC_FLAT" \
  || fail "execute-task must say the release happens before the success/failure branch"
grep -qi 'before deciding whether to retry' "$RUN_FLAT" \
  || fail "run-project must release the coordinator lane before the malformed-JSON retry re-assigns it"
ok "both skills release the lane as soon as the sub-agent returns"

echo
echo "orchestrator-skills-use-pool.test.sh: $PASS checks passed"
