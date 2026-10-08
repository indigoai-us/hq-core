#!/usr/bin/env bash
# Tests for core/scripts/pipeline-lane-rows.sh over a fixture pool and state dir
# (bash 3.2 portable). A stub conduct-pool prints the pool's list JSON.
# shellcheck disable=SC2016  # check() evals single-quoted assertions on purpose
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PLR="$HERE/../pipeline-lane-rows.sh"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/plr-test.XXXXXX")" && pwd -P)"
SLEEPER=""
trap '[ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
unset HQ_SESSION_ID

S="$T/state"; mkdir -p "$S/stories" "$S/handoffs" "$S/driver"
sleep 300 & SLEEPER=$!
NOW="$(date +%s)"

# lane A: backend-dev, live pid, US-1 in flight at phase 2 of 3, one queued envelope, a PR in its handoff
A="$T/lanes/a"; mkdir -p "$A/inbox/pending"
echo '{"pid":1}' > "$A/loop.json"
printf 'first\n' > "$A/agent-1.log"
printf 'older\n   Running   the   tests   \n\n' > "$A/agent-2.log"
touch "$A/inbox/pending/m1.msg" "$A/inbox/pending/.tmp-hidden"
# backdate the newest log by 25 minutes: quiet_s reads its mtime
python3 -c 'import os,sys,time; t=time.time()-1500; os.utime(sys.argv[1],(t,t))' "$A/agent-2.log"
# lane B: qa-tester, dead pid, nothing in flight, exited 0, no PR
B="$T/lanes/b"; mkdir -p "$B"
echo '{"pid":2}' > "$B/loop.json"
printf 'started\nCONDUCT_EXIT=0\n' > "$B/lane.log"
# slot C: a one-shot lane with no loop.json is not a loop lane
C="$T/lanes/c"; mkdir -p "$C"

cat > "$S/stories/US-1.json" <<JSON
{"id":"US-1","title":"Add the export button","state":"in_flight","current":1,"routed_at":$((NOW - 90)),
 "phases":[{"phase":"architect","worker":"architect"},{"phase":"backend","worker":"backend-dev"},{"phase":"qa","worker":"qa-tester"}]}
JSON
echo '{"id":"US-2","title":"t2","state":"verified","current":0,"phases":[{"phase":"backend","worker":"backend-dev"}]}' > "$S/stories/US-2.json"
echo '{"id":"US-3","title":"t3","state":"queued","current":0,"phases":[{"phase":"backend","worker":"backend-dev"}]}' > "$S/stories/US-3.json"
echo '{"id":"US-4","title":"t4","state":"blocked_needs_owner","current":0,"phases":[{"phase":"backend","worker":"backend-dev"}]}' > "$S/stories/US-4.json"
echo '{"id":"US-5","title":"t5","state":"parked_dependency","current":0,"phases":[{"phase":"backend","worker":"backend-dev"}]}' > "$S/stories/US-5.json"
echo '{"id":"US-6","title":"t6","state":"interrupted","current":0,"phases":[{"phase":"qa","worker":"qa-tester"}]}' > "$S/stories/US-6.json"
echo '{"id":"US-7","title":"t7","state":"awaiting_go","current":0,"phases":[{"phase":"backend","worker":"backend-dev"}]}' > "$S/stories/US-7.json"
echo '{"US-8":{"note":"n"}}' > "$S/skips.json"
echo '{"story_id":"US-1","phase":"architect","worker_id":"backend-dev","status":"passed","notes":"see https://github.com/acme/app/pull/42 for it"}' > "$S/handoffs/US-1-architect.json"
echo "$SLEEPER" > "$S/driver/driver.pid"
printf '2026-01-01T00:00:00Z START\n2026-01-01T00:00:05Z TICK: ROUTED US-1 backend\n' > "$S/driver/driver.log"

cat > "$T/pool" <<EOF
#!/bin/sh
[ "\$1" = --session-id ] && echo "\$2" > "$T/pool.sid"
cat <<J
[{"worker_id":"backend-dev","subagent_id":"sub-a","status":"running","last_task":"","updated_at":"","pid":$SLEEPER,"run_dir":"$A","queue_depth":1},
 {"worker_id":"qa-tester","subagent_id":"sub-b","status":"idle","last_task":"","updated_at":"","pid":999999,"run_dir":"$B","queue_depth":0},
 {"worker_id":"designer","subagent_id":"sub-c","status":"idle","last_task":"","updated_at":"","pid":null,"run_dir":"$C","queue_depth":0}]
J
EOF
chmod +x "$T/pool"
export PIPELINE_LANE_ROWS_POOL="$T/pool"

sh "$PLR" --state "$S" --session-id sess-1 > "$T/out" 2>"$T/err"; rc=$?
q() { jq -r "$1" "$T/out"; }
check "exits 0 and prints one JSON array" '[ $rc = 0 ] && [ "$(q "type")" = array ]'
check "one item per loop lane plus the driver; the non-loop slot is left out" \
  '[ "$(q "length")" = 3 ] && [ "$(q "[.[]|select(.kind==\"lane\")|.worker]|join(\",\")")" = "backend-dev,qa-tester" ]'
check "session id reaches the pool" '[ "$(cat "$T/pool.sid")" = sess-1 ]'
L='.[]|select(.worker=="backend-dev")'
check "lane: worker, subagent id, status, pid_alive true" \
  '[ "$(q "$L|[.kind,.subagent_id,.status,.pid_alive]|map(tostring)|join(\" \")")" = "lane sub-a running true" ]'
check "lane: phase_label is story · worker · short verb" '[ "$(q "$L|.phase_label")" = "US-1 · backend-dev · building" ]'
check "lane: story, phase, phase_index 2 of phase_count 3" '[ "$(q "$L|[.story,.phase,.phase_index,.phase_count]|map(tostring)|join(\" \")")" = "US-1 backend 2 3" ]'
check "lane: phase_elapsed_s from routed_at" 'v=$(q "$L|.phase_elapsed_s"); [ "$v" -ge 90 ] && [ "$v" -lt 150 ]'
check "lane: quiet_s from the backdated newest agent log" 'v=$(q "$L|.quiet_s"); [ "$v" -ge 1500 ] && [ "$v" -lt 1600 ]'
check "lane: inbox_pending counts queued envelopes, not dot files" '[ "$(q "$L|.inbox_pending")" = 1 ]'
check "lane: last_line is the newest agent-N.log non-blank line, trimmed" '[ "$(q "$L|.last_line")" = "Running the tests" ]'
check "lane: pr from the newest handoff it wrote" '[ "$(q "$L|.pr")" = "https://github.com/acme/app/pull/42" ]'
check "lane: exit null while lane.log has no CONDUCT_EXIT" '[ "$(q "$L|.exit")" = null ]'
check "lane: story_title" '[ "$(q "$L|.story_title")" = "Add the export button" ]'
check "lane: run_dir" '[ "$(q "$L|.run_dir")" = "$A" ]'
M='.[]|select(.worker=="qa-tester")'
check "idle lane: pid_alive false, exit 0 from lane.log" '[ "$(q "$M|.pid_alive")" = false ] && [ "$(q "$M|.exit")" = 0 ]'
check "idle lane: no story, phase fields null, no PR, no log" \
  '[ "$(q "$M|[.story,.phase_label,.phase_index,.phase_count,.phase_elapsed_s,.quiet_s,.last_line,.pr,.story_title]|map(tostring)|unique|join(\",\")")" = null ]'
check "idle lane: inbox_pending 0 with no inbox" '[ "$(q "$M|.inbox_pending")" = 0 ]'
D='.[]|select(.kind=="driver")'
check "driver: pid_alive true, exit null while running" '[ "$(q "$D|.pid_alive")" = true ] && [ "$(q "$D|.exit")" = null ]'
check "driver: story counts" \
  '[ "$(q "$D|[.verified,.in_flight,.queued,.blocked,.parked,.skipped,.interrupted,.awaiting_go]|map(tostring)|join(\" \")")" = "1 1 1 1 1 1 1 1" ]'
check "driver: last driver.log line" '[ "$(q "$D|.last_line")" = "2026-01-01T00:00:05Z TICK: ROUTED US-1 backend" ]'

# exit present, driver gone
echo "29 stopped on request" > "$S/driver/exit"; echo 999999 > "$S/driver/driver.pid"
sh "$PLR" --state "$S" --session-id sess-1 > "$T/out" 2>/dev/null
check "driver: exit read from driver/exit, pid_alive false" '[ "$(q "$D|.exit")" = "29 stopped on request" ] && [ "$(q "$D|.pid_alive")" = false ]'

# an empty pool: no lanes, the driver item only
printf '#!/bin/sh\necho "[]"\n' > "$T/pool-empty"; chmod +x "$T/pool-empty"
PIPELINE_LANE_ROWS_POOL="$T/pool-empty" sh "$PLR" --state "$S" --session-id sess-1 > "$T/out" 2>/dev/null; rc=$?
check "zero live lanes: driver item only" '[ $rc = 0 ] && [ "$(q "length")" = 1 ] && [ "$(q ".[0].kind")" = driver ]'
check "missing --state is a usage error" '! sh "$PLR" >/dev/null 2>&1'
check "portable shell: bash -n, dash -n, sh -n" 'bash -n "$PLR" && sh -n "$PLR" && { ! command -v dash >/dev/null || dash -n "$PLR"; }'
check "no bash arrays" '! grep -nE "^[^#]*(declare -a|mapfile|readarray|\[@\])" "$PLR" | grep -q .'

echo "pipeline-lane-rows: $pass passed, $fail failed"
[ "$fail" = 0 ]
