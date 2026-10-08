#!/usr/bin/env bash
# Guard: the pipeline test suite never touches a lane it did not start.
#
# Observed 2026-10-05 22:51Z: six idle loop lanes of a live /run-project
# --pipeline run, in another session, each logged "received SIGTERM" while this
# suite ran. The sender was conduct-reap.sh, run by the SessionStart sweep: it
# read detached loop lanes, idle by design and with no owning `claude` process
# in their ancestry, as orphans and stopped them.
#
# This test starts one real loop lane under a separate "foreign" session (its
# own HQ root, session id, run dir and pool slot), launched the way /run-project
# --pipeline launches one (hq-detach.sh, lane.pid, lane.log). It then runs:
#   1. every other pipeline-*.test.sh in this directory,
#   2. the e2e test against a reverted driver (the teeth runs do this), from
#      $ISOLATION_TEETH_DRIVER or, when this tree is a git checkout that has it,
#      the driver at 566a5dbd7,
#   3. the sweep a session start runs (conduct-reap.sh --apply --kill) over the
#      foreign HQ root, with the age gate at 0.
# It asserts the foreign lane is still alive, its lane.log has no SIGTERM line
# and its pool slot is unchanged, then stops it with its own stop envelope.
#
# The other suites' pass/fail is theirs to report; a reverted driver is expected
# to fail. Only the foreign lane is asserted here. bash 3.2 portable.
set -u
unset HQ_SPAWN_COMPANY HQ_PARENT_SESSION_ID HQ_PIPELINE_DECISIONS_FILE HQ_WORKFLOW_LANE \
  CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID HQ_CONDUCT_RUN_DIR \
  PC_WORKERS_ROOT PC_POOL PC_ENVELOPE PC_NOW PC_MAX_STORIES PIPELINE_E2E_DRIVER

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
RUNNER="$SCRIPTS/workflow-runner.mjs"
POOL_SH="$SCRIPTS/conduct-pool.sh"
DETACH="$SCRIPTS/hq-detach.sh"
REAP="$SCRIPTS/conduct-reap.sh"

pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
wait_for() { # wait_for <secs> <command...>
  limit=$(( $1 * 10 )); shift
  i=0
  while [ $i -lt $limit ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pipeline-isolation.XXXXXX")" && pwd -P)"
FPID=""
cleanup() {
  # Only the pid this test started, by pid.
  [ -n "$FPID" ] && kill "$FPID" 2>/dev/null
  [ -n "${KEEP:-}" ] || rm -rf "$T"
}
trap cleanup EXIT

# ---- the foreign session: its own HQ root, session id, run dir, pool slot ----
FHQ="$T/foreign-hq"
FSID="foreign-$$-$(date +%s)"
FRUN="$FHQ/workspace/tmp/workflow-runner/$FSID/run-project-backend-dev-foreign"
mkdir -p "$FHQ/.claude" "$FHQ/workspace/sessions" "$FRUN"
printf '{}\n' > "$FHQ/.claude/settings.json"
fpool() { HQ_ROOT="$FHQ" bash "$POOL_SH" --session-id "$FSID" "$@"; }

HQ_ROOT="$FHQ" HQ_SESSION_ID="$FSID" HQ_WORKFLOW_CPU_CHECK=0 HQ_WORKFLOW_LOOP_POLL_MS=100 \
  bash "$DETACH" --pidfile "$FRUN/lane.pid" --logfile "$FRUN/lane.log" -- \
  node "$RUNNER" --loop --run-dir "$FRUN"
wait_for 15 test -f "$FRUN/loop.json"
FPID="$(tr -dc '0-9' < "$FRUN/lane.pid" 2>/dev/null)"
check "foreign lane started detached, with lane.pid and loop.json" '[ -n "$FPID" ] && kill -0 "$FPID" 2>/dev/null && [ -f "$FRUN/loop.json" ]'
fpool assign --worker-id backend-dev >/dev/null
fpool record --worker-id backend-dev --subagent-id loop-backend-dev --status waiting --pid "$FPID" --run-dir "$FRUN" >/dev/null
fpool list > "$T/slot.before"
check "foreign pool slot recorded waiting" 'grep -q "\"waiting\"" "$T/slot.before"'

# ---- 1. every other pipeline suite ----
for t in "$HERE"/pipeline-*.test.sh; do
  [ "$t" = "$HERE/pipeline-isolation.test.sh" ] && continue
  bash "$t" > "$T/$(basename "$t").log" 2>&1; rc=$?
  echo "ran $(basename "$t") rc=$rc ($(tail -1 "$T/$(basename "$t").log" | cut -c1-60))"
done

# ---- 2. the e2e test against a reverted driver ----
OLD="${ISOLATION_TEETH_DRIVER:-}"
if [ -z "$OLD" ] && git -C "$SCRIPTS" cat-file -e 566a5dbd7:core/scripts/pipeline-driver.sh 2>/dev/null; then
  OLD="$T/driver-566a5dbd7.sh"
  git -C "$SCRIPTS" show 566a5dbd7:core/scripts/pipeline-driver.sh > "$OLD"
fi
if [ -n "$OLD" ] && [ -f "$OLD" ]; then
  PIPELINE_E2E_DRIVER="$OLD" PIPELINE_DRIVER_CONDUCTOR="$SCRIPTS/pipeline-conductor.sh" \
    bash "$HERE/pipeline-e2e.test.sh" > "$T/teeth-e2e.log" 2>&1; rc=$?
  echo "ran pipeline-e2e.test.sh with the reverted driver rc=$rc ($(tail -1 "$T/teeth-e2e.log" | cut -c1-60))"
else
  echo "NOTE: no reverted driver available (set ISOLATION_TEETH_DRIVER); step 2 not run"
fi

# ---- 3. the sweep a session start runs, over the foreign HQ root ----
if [ -f "$REAP" ]; then
  HQ_ROOT="$FHQ" bash "$REAP" --apply --kill --min-age 0 > "$T/reap.log" 2>&1
  echo "ran conduct-reap.sh --apply --kill --min-age 0: $(grep -c '' "$T/reap.log") line(s)"
  check "the sweep keeps the loop lane" 'grep -q "^keep     loop .*run-project-backend-dev-foreign" "$T/reap.log"'
else
  echo "NOTE: no conduct-reap.sh next to these scripts; step 3 not run"
fi

# ---- the foreign lane is untouched ----
check "foreign lane still alive" 'kill -0 "$FPID" 2>/dev/null'
check "foreign lane.log has no SIGTERM line" '! grep -q "SIGTERM" "$FRUN/lane.log"'
fpool list > "$T/slot.after"
check "foreign pool slot untouched" 'cmp -s "$T/slot.before" "$T/slot.after"'
check "foreign lane markers still in place" '[ -s "$FRUN/lane.pid" ] && [ -f "$FRUN/loop.json" ]'

# ---- stop it with its own stop envelope ----
printf '{"kind":"stop"}\n' > "$T/stop.json"
fpool assign --worker-id backend-dev --envelope "$T/stop.json" > "$T/stop.out" 2>&1
check "foreign lane stops on its own stop envelope" \
  'grep -q "\"action\":\"enqueue\"" "$T/stop.out" && wait_for 15 eval "! kill -0 $FPID 2>/dev/null"'
kill -0 "$FPID" 2>/dev/null || FPID=""

echo "pipeline-isolation: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
