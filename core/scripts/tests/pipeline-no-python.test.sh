#!/usr/bin/env bash
# pipeline-driver.sh runs on a machine with no python3.
#
# PATH is cut down to one temp dir of symlinks: a shell, jq, node, git and the
# coreutils the pipeline scripts call. python3 is not in it. The driver runs
# against a hand-written state dir and a stub pool (the early-exit fixture), so
# one tick goes through the driver's scan, the conductor and the envelope check.
# The test asserts the same TICK line the early-exit suite asserts with the full
# PATH, and that no script asked for python3.
#
# PIPELINE_NOPY_DRIVER points the test at another driver copy (used to show the
# check fails against the python3 driver).
# bash 3.2 portable.
set -u
unset HQ_SPAWN_COMPANY HQ_PARENT_SESSION_ID HQ_PIPELINE_DECISIONS_FILE HQ_WORKFLOW_LANE \
  CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID \
  PC_WORKERS_ROOT PC_POOL PC_ENVELOPE PC_NOW PC_MAX_STORIES PIPELINE_DRIVER_POOL
export HQ_SESSION_ID="test-pipeline-no-python-$$"

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
DRIVER="${PIPELINE_NOPY_DRIVER:-$SCRIPTS/pipeline-driver.sh}"

pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
wait_for() { limit=$(( $1 * 10 )); shift; i=0; while [ $i -lt $limit ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pipeline-nopy.XXXXXX")" && pwd -P)"
DPID=""
cleanup() {
  [ -n "$DPID" ] && kill "$DPID" 2>/dev/null
  [ -n "${KEEP:-}" ] || rm -rf "$T"
}
trap cleanup EXIT
export HQ_ROOT="$T/hq" PC_HQ_ROOT="$T/hq"
mkdir -p "$T/hq/workspace/sessions"

# ---- a PATH with no python3 ----
BIN="$T/bin"; mkdir -p "$BIN"
missing=""
for tool in sh bash dash jq node git env cat date mkdir rm mv cp ls ps grep sed tr cut head tail wc sort \
            awk dirname basename mktemp sleep touch chmod find uname tee ln readlink stat; do
  p="$(command -v "$tool" 2>/dev/null)"
  case "$p" in
    /*) ln -s "$p" "$BIN/$tool" ;;
    *) case "$tool" in dash|stat|readlink) ;; *) missing="$missing $tool" ;; esac ;;
  esac
done
check "the stripped PATH has every required tool" '[ -z "$missing" ]'
check "python3 does not resolve on the stripped PATH" '! PATH="$BIN" command -v python3 >/dev/null 2>&1'

# ---- fixture: S1 in flight, the lane journalled an early engine exit ----
C="$T/case"; S="$C/state"; LANE="$C/lane"
mkdir -p "$S/stories" "$S/envelopes" "$S/handoffs" "$S/driver" "$LANE"
printf '{"name":"nopy","userStories":[{"id":"S1","title":"t","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["a"]}]}\n' > "$C/prd.json"
printf '{"id":"S1","title":"t","phases":[{"phase":"backend","worker":"backend-dev"}],"current":0,"state":"in_flight","reroutes":0,"worktree":"%s","started":true,"routed_at":%s}\n' \
  "$C" "$(( $(date +%s) - 30 ))" > "$S/stories/S1.json"
printf '{"deadline":"2999-01-01T00:00:00Z"}\n' > "$S/envelopes/S1-backend.json"
printf '{"ts":"%s","event":"phase-exit","story_id":"S1","phase":"backend","worker_id":"backend-dev","reason":"engine error: exit code 1","exit_reason":"engine_exited_early","elapsed_s":7}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > "$LANE/journal.jsonl"
cat > "$C/pool" <<POOL
#!/bin/sh
case "\$1" in
  list) printf '[{"worker_id":"backend-dev","status":"running","pid":1,"run_dir":"%s","queue_depth":0}]\n' "$LANE" ;;
  assign) echo "\$*" >> "$C/assigns"; printf '{"action":"enqueue","worker_id":"backend-dev","pid":1,"queued":"%s/q.msg","queue_depth":1}\n' "$LANE" ;;
  *) : ;;
esac
POOL
chmod +x "$C/pool"

PATH="$BIN" PC_POOL="$C/pool" PIPELINE_DRIVER_POOL="$C/pool" PIPELINE_DRIVER_CONDUCTOR="$SCRIPTS/pipeline-conductor.sh" \
  PC_ENVELOPE="$SCRIPTS/pipeline-envelope.sh" \
  "$BIN/sh" "$DRIVER" --prd "$C/prd.json" --state "$S" --interval 0.2 >"$C/out" 2>"$C/err" &
DPID=$!
wait_for 20 test -s "$C/assigns"
sleep 0.5

check "TICK: the early exit is reported with story, phase and elapsed time" \
  'grep -qs "TICK: EARLY_EXIT S1/backend after 7s: engine_exited_early (engine error: exit code 1)" "$S/driver/driver.log"'
check "TICK: the phase was routed again to the same lane" \
  '[ "$(grep -c "assign --worker-id backend-dev" "$C/assigns" 2>/dev/null)" = 1 ]'
check "the early-exit handoff was written and accepted" \
  '[ "$(jq -r .exit_reason "$S/handoffs/S1-backend.failed.1.json" 2>/dev/null)" = engine_exited_early ]'
check "no script asked for python3" '! grep -qs "python3" "$C/err" "$S/driver/driver.log"'
check "the driver is still running (no exit file)" 'kill -0 "$DPID" 2>/dev/null && [ ! -f "$S/driver/exit" ]'
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=""

echo "pipeline-no-python: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
