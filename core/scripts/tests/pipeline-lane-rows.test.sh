#!/usr/bin/env bash
# pipeline-lane-rows contract over a fake hq lanes list response.
# shellcheck disable=SC2016  # check() evals single-quoted assertions on purpose
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PLR="$HERE/../pipeline-lane-rows.sh"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/plr-test.XXXXXX")" && pwd -P)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$T/bin" "$T/state/stories" "$T/state/handoffs" "$T/state/driver"
cat > "$T/bin/hq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_HQ_LOG"
[ "$1 $2" = "lanes list" ] || exit 2
cat "$FAKE_HQ_LIST"
EOF
chmod +x "$T/bin/hq"
export PC_HQ="$T/bin/hq" FAKE_HQ_LOG="$T/hq.log" FAKE_HQ_LIST="$T/lanes.json" PATH="$T/bin:$PATH"
NOW="$(date +%s)"
ROUTED=$((NOW - 90))
cat > "$T/state/lanes.json" <<'EOF'
{"backend-dev":"lane-a","qa-tester":"lane-b"}
EOF
cat > "$T/state/stories/US-1.json" <<EOF
{"id":"US-1","title":"Add the export button","state":"in_flight","current":1,"routed_at":$ROUTED,
 "phases":[{"phase":"architect","worker":"architect"},{"phase":"backend","worker":"backend-dev"},{"phase":"qa","worker":"qa-tester"}]}
EOF
echo '{"id":"US-2","state":"verified","current":0,"phases":[{"phase":"backend","worker":"backend-dev"}]}' > "$T/state/stories/US-2.json"
echo '{"id":"US-3","state":"queued","current":0,"phases":[{"phase":"backend","worker":"backend-dev"}]}' > "$T/state/stories/US-3.json"
echo '{"id":"US-4","state":"blocked_needs_owner","current":0,"phases":[{"phase":"backend","worker":"backend-dev"}]}' > "$T/state/stories/US-4.json"
echo '{"id":"US-5","state":"parked_dependency","current":0,"phases":[{"phase":"backend","worker":"backend-dev"}]}' > "$T/state/stories/US-5.json"
echo '{"id":"US-6","state":"interrupted","current":0,"phases":[{"phase":"qa","worker":"qa-tester"}]}' > "$T/state/stories/US-6.json"
echo '{"id":"US-7","state":"awaiting_go","current":0,"phases":[{"phase":"backend","worker":"backend-dev"}]}' > "$T/state/stories/US-7.json"
echo '{"US-8":{"note":"n"}}' > "$T/state/skips.json"
echo '{"story_id":"US-1","phase":"architect","worker_id":"backend-dev","status":"passed","notes":"see https://github.com/acme/app/pull/42 for it"}' > "$T/state/handoffs/US-1-architect.json"
echo "$$" > "$T/state/driver/driver.pid"
printf '2026-01-01T00:00:00Z START\n2026-01-01T00:00:05Z TICK: ROUTED US-1 backend\n' > "$T/state/driver/driver.log"
cat > "$T/lanes.json" <<'EOF'
[{"lane_id":"lane-a","loop":{"state":"waiting","queue_depth":1,"pid":1},"last_line":"Running the tests","pr":"https://github.com/acme/app/pull/42","inbox_pending":1,"elapsed_s":92},
 {"lane_id":"lane-b","loop":{"state":"stopped","queue_depth":0},"last_line":null,"pr":null,"inbox_pending":0,"elapsed_s":0},
 {"lane_id":"unmapped","loop":{"state":"waiting","queue_depth":0,"pid":3}}]
EOF

sh "$PLR" --state "$T/state" --session-id sess-1 > "$T/out" 2> "$T/err"; rc=$?
cp "$T/out" "$T/initial.json"
q() { jq -r "$1" "$T/out"; }
check "exits 0 and prints one JSON array" '[ $rc = 0 ] && [ "$(q "type")" = array ]'
check "only mapped loop lanes and the driver are rendered" '[ "$(q "length")" = 3 ] && [ "$(q "[.[]|select(.kind==\"lane\")|.worker]|join(\",\")")" = "backend-dev,qa-tester" ]'
check "hq lanes list is called with JSON output" 'grep -q "^lanes list --json$" "$FAKE_HQ_LOG"'
L='.[]|select(.worker=="backend-dev")'
check "lane id, loop state and pid presence map to row fields" '[ "$(q "$L|[.kind,.subagent_id,.status,.pid_alive]|map(tostring)|join(\" \")")" = "lane lane-a waiting true" ]'
check "story and phase label come from pipeline state" '[ "$(q "$L|.story")" = US-1 ] && [ "$(q "$L|.phase_label")" = "US-1 · backend-dev · building" ]'
check "phase index and count come from pipeline state" '[ "$(q "$L|[.phase,.phase_index,.phase_count]|map(tostring)|join(\" \")")" = "backend 2 3" ]'
check "elapsed time and CL-1 lane fields come from the pipeline state and hq lanes list" '[ "$(q "$L|.phase_elapsed_s")" -ge 90 ] && [ "$(q "$L|.phase_elapsed_s")" -lt 120 ] && [ "$(q "$L|[.inbox_pending,.last_line,.pr]|map(tostring)|join(\"|\")")" = "1|Running the tests|https://github.com/acme/app/pull/42" ]'
check "lane internals are not read for quiet time, exit or run directory" '[ "$(q "$L|[.quiet_s,.exit,.run_dir]|map(tostring)|join(\" \")")" = "null null null" ]'
M='.[]|select(.worker=="qa-tester")'
check "stopped lane with no pid has no active story or PR" '[ "$(q "$M|[.status,.pid_alive,.story,.pr,.inbox_pending]|map(tostring)|join(\" \")")" = "stopped false null null 0" ]'
D='.[]|select(.kind=="driver")'
check "driver counts and last line remain available" '[ "$(q "$D|[.pid_alive,.verified,.in_flight,.queued,.blocked,.parked,.skipped,.interrupted,.awaiting_go]|map(tostring)|join(\" \")")" = "true 1 1 1 1 1 1 1 1" ] && [ "$(q "$D|.last_line")" = "2026-01-01T00:00:05Z TICK: ROUTED US-1 backend" ]'
echo "29 stopped on request" > "$T/state/driver/exit"; echo 999999 > "$T/state/driver/driver.pid"
sh "$PLR" --state "$T/state" --session-id sess-1 > "$T/out" 2>/dev/null
check "driver exit is read from driver/exit" '[ "$(q "$D|.exit")" = "29 stopped on request" ] && [ "$(q "$D|.pid_alive")" = false ]'
echo '[]' > "$T/lanes.json"
sh "$PLR" --state "$T/state" --session-id sess-1 > "$T/out" 2>/dev/null; rc=$?
check "empty hq lane list renders only the driver" '[ $rc = 0 ] && [ "$(q "length")" = 1 ] && [ "$(q ".[0].kind")" = driver ]'
check "missing --state is a usage error" '! sh "$PLR" >/dev/null 2>&1'
check "portable shell and no bash arrays" 'bash -n "$PLR" && sh -n "$PLR" && { ! command -v dash >/dev/null || dash -n "$PLR"; } && ! grep -nE "^[^#]*(declare -a|mapfile|readarray|\[@\])" "$PLR" | grep -q .'
echo "pipeline-lane-rows: $pass passed, $fail failed"
[ "$fail" = 0 ]
