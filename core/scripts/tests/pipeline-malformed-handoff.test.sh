#!/usr/bin/env bash
# A malformed worker handoff (pipeline-conductor.sh accept, pipeline-driver.sh).
#
# Conductor, accept on an in-flight story:
#   1. a handoff with missing fields -> exit 10 PHASE_NEEDS_REPAIR, the story is
#      held (blocked_needs_owner, kind needs_repair) naming each field, never failed;
#   2. a handoff that is not JSON -> the same hold, reason "not valid JSON";
#   3. a handoff the lane runner synthesized after it rejected the worker's reply
#      (summary prefix or synthesized_by marker) -> held, never taken as the
#      worker's own; one written for an engine error stays a failed phase;
#   in every hold the handoff file is left byte-for-byte and a copy sits at
#   <id>-<phase>.malformed.<n>.json; resolve --as retry still works.
# Driver:
#   4. bad JSON, a missing field, or a synthetic runner handoff -> no exit 23:
#      the driver exits 21 naming the repair and the field, the file untouched;
#   5. an early-exit rewrite copies the lane-written file to .orig.<n>.json first.
# bash 3.2 portable.
# shellcheck disable=SC2016  # check() evals single-quoted assertions on purpose
set -u
unset HQ_SPAWN_COMPANY HQ_PARENT_SESSION_ID HQ_PIPELINE_DECISIONS_FILE HQ_WORKFLOW_LANE \
  CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID \
  PC_WORKERS_ROOT PC_WORKERS_REGISTRY PC_PACKS_ROOT PC_HQ PC_ENVELOPE PC_NOW PC_MAX_STORIES PC_TABLE
export HQ_SESSION_ID="test-pipeline-malformed-$$"

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
PC="$SCRIPTS/pipeline-conductor.sh"
DRIVER="$SCRIPTS/pipeline-driver.sh"

pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
alive_not() { ! kill -0 "$1" 2>/dev/null; }
wait_for() { limit=$(( $1 * 10 )); shift; i=0; while [ $i -lt $limit ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
pyget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pipeline-malformed.XXXXXX")" && pwd -P)"
DPIDS=""
cleanup() {
  for p in $DPIDS; do kill "$p" 2>/dev/null; done
  [ -n "${KEEP:-}" ] || rm -rf "$T"
}
trap cleanup EXIT
export HQ_ROOT="$T/hq" PC_HQ_ROOT="$T/hq"
mkdir -p "$HQ_ROOT/workspace/sessions" "$HQ_ROOT/core/scripts" "$T/bin"
cat > "$HQ_ROOT/core/scripts/hq-session.sh" <<'SESSION'
#!/usr/bin/env bash
case "$*" in current) printf 'test-session\n' ;; *company_slug*) printf 'test-co\n' ;; esac
SESSION
chmod +x "$HQ_ROOT/core/scripts/hq-session.sh"

W="$T/workers"
mkdir -p "$W/backend-dev" "$W/qa-tester"
printf 'worker:\n  id: backend-dev\n  type: CodeWorker\n' > "$W/backend-dev/worker.yaml"
printf 'worker:\n  id: qa-tester\n  type: OpsWorker\n' > "$W/qa-tester/worker.yaml"
export PC_WORKERS_ROOT="$W"

cat > "$T/prd.json" <<'EOF'
{"name":"malformed","userStories":[{"id":"S1","title":"t","passes":false,"dependsOn":[],"files":["src/a.ts"],"worker_preference":["backend-dev","qa-tester"],"acceptanceCriteria":["a"]}]}
EOF

# in_flight <state dir>: S1 classified and in flight on its backend phase
in_flight() {
  mkdir -p "$1/handoffs"
  "$PC" classify --prd "$T/prd.json" --state "$1" --story S1 >/dev/null 2>&1
  jq --argjson t "$(( $(date +%s) - 30 ))" '.state = "in_flight" | .started = true | .routed_at = $t' \
    "$1/stories/S1.json" > "$T/st.tmp" && mv "$T/st.tmp" "$1/stories/S1.json"
  printf '{"deadline":"2999-01-01T00:00:00Z"}\n' > "$T/env.tmp"
  mkdir -p "$1/envelopes" && mv "$T/env.tmp" "$1/envelopes/S1-backend.json"
}
run() { "$PC" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }
state() { pyget "$1/stories/S1.json" "d['state']"; }
blocked() { pyget "$1/stories/S1.json" "d.get('blocked', {}).get('$2')"; }

MISSING='{"schema":"hq-phase-handoff/v1","story_id":"S1","phase":"backend","worker_id":"backend-dev","status":"passed","files_changed":[],"back_pressure":{"tests":"pass","lint":"skip","typecheck":"skip","build":"skip"},"context_for_next":"c"}'
BADJSON='{"schema":"hq-phase-handoff/v1","story_id":"S1","phase":"backend","status":"pass'
synthetic() { # synthetic <reason> [marker]: a handoff the lane runner wrote in place of the worker's
  printf '{"schema":"hq-phase-handoff/v1","story_id":"S1","phase":"backend","worker_id":"backend-dev","status":"failed","summary":"phase did not produce a valid handoff: %s","files_changed":[],"commits":[],"back_pressure":{"tests":"skip","lint":"skip","typecheck":"skip","build":"skip"},"context_for_next":"","engine":"claude","notes":"%s","exit_reason":"engine_exited_early"%s}\n' \
    "$1" "$1" "${2:-}"
}

# ---- 1. missing fields ----------------------------------------------------------
S="$T/c1/state"; in_flight "$S"
H="$S/handoffs/S1-backend.json"
printf '%s\n' "$MISSING" > "$H"; cp "$H" "$T/c1.orig"
run accept --state "$S" --story S1 --handoff "$H"
check "1: a handoff with missing fields exits 10 PHASE_NEEDS_REPAIR" \
  '[ "$(rc)" = 10 ] && grep -q "^PHASE_NEEDS_REPAIR S1 backend .*decisions/S1-blocked-backend.md" "$T/out"'
check "1: the story is held for repair, not failed" \
  '[ "$(state "$S")" = blocked_needs_owner ] && [ "$(blocked "$S" kind)" = needs_repair ]'
check "1: the missing fields are named on the story and in the decision item" \
  '[ "$(pyget "$S/stories/S1.json" "\",\".join(d[\"blocked\"][\"fields\"])")" = "summary,commits" ] && grep -q "missing field: summary" "$S/decisions/S1-blocked-backend.md" && grep -q "fields: summary, commits" "$S/decisions/S1-blocked-backend.md"'
check "1: the handoff is left byte-for-byte and a copy is kept" \
  'cmp -s "$H" "$T/c1.orig" && cmp -s "$S/handoffs/S1-backend.malformed.1.json" "$T/c1.orig"'
run resolve --prd "$T/prd.json" --state "$S" --story S1 --as retry --note "rerun"
check "1: resolve --as retry reruns the phase and the copy stays" \
  '[ "$(rc)" = 0 ] && [ "$(state "$S")" = queued ] && cmp -s "$S/handoffs/S1-backend.malformed.1.json" "$T/c1.orig"'

# ---- 2. not JSON ----------------------------------------------------------------
S="$T/c2/state"; in_flight "$S"
H="$S/handoffs/S1-backend.json"
printf '%s' "$BADJSON" > "$H"; cp "$H" "$T/c2.orig"
run accept --state "$S" --story S1 --handoff "$H"
check "2: a handoff that is not JSON is held for repair (exit 10)" \
  '[ "$(rc)" = 10 ] && [ "$(state "$S")" = blocked_needs_owner ] && [ "$(blocked "$S" kind)" = needs_repair ]'
check "2: the reason says it is not valid JSON" 'grep -q "handoff needs repair: not valid JSON" "$S/stories/S1.json"'
check "2: the handoff is left byte-for-byte and a copy is kept" \
  'cmp -s "$H" "$T/c2.orig" && cmp -s "$S/handoffs/S1-backend.malformed.1.json" "$T/c2.orig"'

# ---- 3. runner-synthesized handoffs ---------------------------------------------
S="$T/c3/state"; in_flight "$S"
H="$S/handoffs/S1-backend.json"
synthetic "reply is not a valid handoff: missing field: commits" > "$H"; cp "$H" "$T/c3.orig"
run accept --state "$S" --story S1 --handoff "$H"
check "3: a runner handoff for a rejected reply is not taken as the worker's own (held, not failed)" \
  '[ "$(rc)" = 10 ] && [ "$(state "$S")" = blocked_needs_owner ] && [ "$(blocked "$S" synthetic)" = True ]'
check "3: the reason names the runner and the rejected field" \
  'grep -q "runner-synthesized handoff, not the worker" "$S/decisions/S1-blocked-backend.md" && grep -q "missing field: commits" "$S/decisions/S1-blocked-backend.md"'
check "3: the synthetic handoff is left as written and copied" \
  'cmp -s "$H" "$T/c3.orig" && cmp -s "$S/handoffs/S1-backend.malformed.1.json" "$T/c3.orig"'

S="$T/c3b/state"; in_flight "$S"
H="$S/handoffs/S1-backend.json"
printf '{"x":1}\n' > "$S/handoffs/S1-backend.orig.1.json"
synthetic "handoff check failed: worker_id mismatch" ',"synthesized_by":"lane-runner","worker_handoff":"'"$S"'/handoffs/S1-backend.orig.1.json"' > "$H"
# the marker alone is enough: drop the summary prefix
jq '.summary = "rejected"' "$H" > "$T/h.tmp" && mv "$T/h.tmp" "$H"
run accept --state "$S" --story S1 --handoff "$H"
check "3: the synthesized_by marker alone marks a runner handoff, and the kept worker file is named" \
  '[ "$(rc)" = 10 ] && [ "$(blocked "$S" synthetic)" = True ] && grep -q "kept the worker.s file at $S/handoffs/S1-backend.orig.1.json" "$S/decisions/S1-blocked-backend.md"'

S="$T/c3c/state"; in_flight "$S"
H="$S/handoffs/S1-backend.json"
synthetic "engine error: exit code 1" > "$H"
run accept --state "$S" --story S1 --handoff "$H"
check "3: a runner handoff for an engine error stays a failed phase (early-exit path)" \
  '[ "$(rc)" = 1 ] && grep -q "^PHASE_FAILED S1 backend" "$T/out" && [ "$(state "$S")" = queued ]'

S="$T/c3d/state"; in_flight "$S"
jq '.state = "queued"' "$S/stories/S1.json" > "$T/st.tmp" && mv "$T/st.tmp" "$S/stories/S1.json"
printf '%s\n' "$MISSING" > "$T/c3d.json"
run accept --state "$S" --story S1 --handoff "$T/c3d.json"
check "3: a story not in flight still refuses a malformed handoff, naming the field" \
  '[ "$(rc)" != 0 ] && [ "$(rc)" != 10 ] && grep -q "invalid handoff: .*missing field: summary" "$T/err" && [ "$(state "$S")" = queued ]'

# ---- 4. driver ------------------------------------------------------------------
# fake hq: one loop lane that is waiting, so only the handoff file moves the story
cat > "$T/bin/hq" <<'EOF'
#!/bin/sh
case "$1" in
  lanes)
    case "$2" in
      create) printf '{"ok":true,"lane_id":"lane-backend-dev"}\n' ;;
      enqueue) printf '%s\n' "$*" >> "$HQ_TEST_CALLS"; printf '{"ok":true}\n' ;;
      list) printf '[{"lane_id":"lane-backend-dev","loop":{"state":"waiting","queue_depth":1,"pid":1}}]\n' ;;
      *) printf '{"ok":true,"withdrawn":[],"already_picked_up":[]}\n' ;;
    esac ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/hq"
exit_code() { [ -f "$1/driver/exit" ] && cut -d' ' -f1 "$1/driver/exit"; }
drive() { # drive <case>: run the driver on a prepared state until it exits
  S="$T/$1/state"; export HQ_TEST_CALLS="$T/$1/calls"; : > "$HQ_TEST_CALLS"
  mkdir -p "$S/driver"
  PIPELINE_DRIVER_HANDOFF_SETTLE_SECS=0 PC_HQ="$T/bin/hq" sh "$DRIVER" --prd "$T/prd.json" --state "$S" \
    --interval 0.2 >"$T/$1/driver.out" 2>&1 &
  DPID=$!; DPIDS="$DPIDS $DPID"
  wait_for 30 test -f "$S/driver/exit"
  # let it finish on its own: a signal during its exit cleanup rewrites driver/exit
  wait_for 10 alive_not "$DPID"
  kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
}

S="$T/d1/state"; in_flight "$S"
printf '%s' "$BADJSON" > "$S/handoffs/S1-backend.json"; cp "$S/handoffs/S1-backend.json" "$T/d1.orig"
drive d1
check "4: bad JSON does not kill the driver with 23; it exits 21 naming the repair" \
  '[ "$(exit_code "$S")" = 21 ] && grep -q "malformed handoff, needs repair: S1/backend: handoff needs repair: not valid JSON" "$S/driver/exit"'
check "4: bad JSON: the handoff file is untouched and the story is held, not failed" \
  'cmp -s "$S/handoffs/S1-backend.json" "$T/d1.orig" && [ "$(state "$S")" = blocked_needs_owner ] && [ "$(grep -c "^lanes enqueue" "$T/d1/calls")" = 0 ]'

S="$T/d2/state"; in_flight "$S"
printf '%s\n' "$MISSING" > "$S/handoffs/S1-backend.json"; cp "$S/handoffs/S1-backend.json" "$T/d2.orig"
drive d2
check "4: a missing field exits 21 naming the field, not 23" \
  '[ "$(exit_code "$S")" = 21 ] && grep -q "missing field: summary" "$S/driver/exit" && cmp -s "$S/handoffs/S1-backend.json" "$T/d2.orig"'

S="$T/d3/state"; in_flight "$S"
synthetic "reply did not normalize: no JSON object found" > "$S/handoffs/S1-backend.json"
cp "$S/handoffs/S1-backend.json" "$T/d3.orig"
drive d3
check "4: a synthetic runner handoff is not re-routed as an early exit; it is held for repair" \
  '[ "$(exit_code "$S")" = 21 ] && grep -q "runner-synthesized handoff" "$S/driver/exit" && ! grep -q EARLY_EXIT "$S/driver/driver.log" && [ "$(grep -c "^lanes enqueue" "$T/d3/calls")" = 0 ]'
check "4: the synthetic handoff file is left as written" 'cmp -s "$S/handoffs/S1-backend.json" "$T/d3.orig"'

# ---- 5. early-exit rewrite keeps the original ----------------------------------
S="$T/d5/state"; in_flight "$S"
synthetic "engine error: exit code 1" > "$S/handoffs/S1-backend.json"
cp "$S/handoffs/S1-backend.json" "$T/d5.orig"
export HQ_TEST_CALLS="$T/d5/calls"; : > "$HQ_TEST_CALLS"
mkdir -p "$S/driver"
PC_HQ="$T/bin/hq" sh "$DRIVER" --prd "$T/prd.json" --state "$S" --interval 0.2 >"$T/d5/driver.out" 2>&1 &
DPID=$!; DPIDS="$DPIDS $DPID"
wait_for 30 grep -qs "^lanes enqueue" "$HQ_TEST_CALLS"
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
check "5: an engine-error early exit is still re-routed" 'grep -q "EARLY_EXIT S1/backend" "$S/driver/driver.log"'
check "5: the lane-written handoff was copied to .orig.1.json before the rewrite" \
  'cmp -s "$S/handoffs/S1-backend.orig.1.json" "$T/d5.orig"'

# 6. a settle window that is not a whole number of seconds is refused up front
PIPELINE_DRIVER_HANDOFF_SETTLE_SECS=abc sh "$DRIVER" --prd "$T/prd.json" --state "$T/d6-state" >"$T/d6.out" 2>&1; d6=$?
check "6: a bad PIPELINE_DRIVER_HANDOFF_SETTLE_SECS exits 2 and names the variable" \
  '[ "$d6" = 2 ] && grep -q "PIPELINE_DRIVER_HANDOFF_SETTLE_SECS must be a whole number" "$T/d6.out"'

echo "pipeline-malformed-handoff: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
