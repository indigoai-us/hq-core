#!/bin/bash
# hq-core: public
# Regression test for `workflow-runner.mjs --loop` — a persistent worker lane
# that takes phase envelopes from the run directory's pending queue.
#
# Uses a FAKE claude binary (HQ_WORKFLOW_CLAUDE_BIN) that records each call, so
# no real agent runs, and a synthetic HQ root. Covered behaviors:
#   1. one envelope written to pending/ produces a result file and ends in
#      claimed/; the lane keeps running afterwards
#   2. an idle lane makes zero engine calls (fast poll interval, several
#      seconds of empty queue)
#   3. two envelopes queued while a phase runs are both processed, in arrival
#      order, including two sends inside the same second
#   4. a stop envelope makes the lane exit 0 after the in-flight phase, and
#      nothing remains in pending/
#   5. the engine child does not inherit HQ_CONDUCT_RUN_DIR, so the lane's
#      inbox hook cannot drain the work queue from inside a phase
#   6. --loop refuses a script argument; a failing phase writes an error
#      result and the lane carries on

set -uo pipefail
unset HQ_SPAWN_COMPANY HQ_SESSION_ID HQ_PARENT_SESSION_ID
# Isolation: this suite never inherits the caller's session. Its own session id,
# and (below) its own HQ_ROOT with workspace/sessions and run dirs under a temp root,
# keep every pool call, lane and signal inside what this test started.
export HQ_SESSION_ID="test-workflow-runner-loop-$$"

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RUNNER="$REPO_ROOT/core/scripts/workflow-runner.mjs"

pass=0
fail=0
check() {
  if [ "$2" -eq 0 ]; then printf 'ok   - %s\n' "$1"; pass=$((pass + 1))
  else printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); fi
}

TMP="$(mktemp -d /tmp/workflow-runner-loop-test.XXXXXX)"
TMP="$(cd "$TMP" && pwd -P)"
LANE_PID=""
cleanup() {
  [ -n "$LANE_PID" ] && kill "$LANE_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/rec"
HQROOT="$TMP/hqroot"
mkdir -p "$HQROOT/.claude" "$HQROOT/workspace"
printf '{}\n' > "$HQROOT/.claude/settings.json"

cat > "$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
rec="${FAKE_REC_DIR:?}"
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --model|--effort|--permission-mode|--output-format|--disallowed-tools) shift 2 ;;
    *) shift ;;
  esac
done
tag="$(printf '%s' "$prompt" | sed -n 's/.*TAG=\([A-Za-z0-9_-]*\).*/\1/p')"
printf '%s %s\n' "$(date +%s)" "$tag" >> "$rec/calls"
printf '%s\n' "${HQ_CONDUCT_RUN_DIR:-<unset>}" > "$rec/conduct-env.$tag"
case "$prompt" in
  *SLEEP=*) sleep "$(printf '%s' "$prompt" | sed -n 's/.*SLEEP=\([0-9]*\).*/\1/p')" ;;
esac
case "$prompt" in
  *FAIL*) echo "fake claude: failing on purpose" >&2; exit 3 ;;
esac
printf '{"type":"result","subtype":"success","is_error":false,"result":"done %s"}\n' "$tag"
FAKE
chmod +x "$TMP/bin/claude"

export HQ_ROOT="$HQROOT"
export HQ_WORKFLOW_CLAUDE_BIN="$TMP/bin/claude"
export HQ_WORKFLOW_CLAUDE_EXEC_MODEL="fake-model"
export HQ_WORKFLOW_CPU_CHECK=0
export HQ_WORKFLOW_LOOP_POLL_MS=50
export FAKE_REC_DIR="$TMP/rec"
# A real conduct lane launch sets this; the runner must not pass it on.
export HQ_CONDUCT_RUN_DIR="$TMP/lane"

LANE="$TMP/lane"
mkdir -p "$LANE"

QUEUE_SEQ=0
send() {
  local stamp target
  mkdir -p "$LANE/inbox/pending"
  QUEUE_SEQ=$((QUEUE_SEQ + 1))
  stamp="$(date -u +%Y%m%d%H%M%S)"
  target="$LANE/inbox/pending/$stamp-$$-$QUEUE_SEQ.msg"
  printf '%s\n' "$1" > "$target"
}
phase() { printf '{"kind":"phase","engine":"claude","tier":"exec","id":"%s","prompt":"TAG=%s %s"}' "$1" "$1" "${2:-}"; }
calls() { [ -f "$TMP/rec/calls" ] && wc -l < "$TMP/rec/calls" | tr -d ' ' || echo 0; }
wait_for() { # wait_for <secs> <command...>
  local limit=$(( $1 * 10 )); shift
  local i=0
  while [ $i -lt $limit ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
results_count() { find "$LANE/inbox/results" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
results_at_least() { [ "$(results_count)" -ge "$1" ]; }

# ---- 6a. --loop refuses a script ---------------------------------------------
node "$RUNNER" --loop "$TMP/x.mjs" --run-dir "$TMP/other" >/dev/null 2>&1
check "--loop with a script path exits 2" "$([ $? -eq 2 ]; echo $?)"

# ---- start the lane ----------------------------------------------------------
node "$RUNNER" --loop --quiet --run-dir "$LANE" > "$TMP/lane.out" 2> "$TMP/lane.err" &
LANE_PID=$!
wait_for 10 test -f "$LANE/loop.json"
check "lane writes loop.json with its pid" \
  "$(node -e 'const j=require(process.argv[1]); process.exit(j.pid==process.argv[2]?0:1)' "$LANE/loop.json" "$LANE_PID"; echo $?)"

# ---- 2. idle lane makes no engine calls --------------------------------------
sleep 3
check "idle lane: zero engine calls over 3s at a 50ms poll" "$([ "$(calls)" = 0 ]; echo $?)"
check "idle lane is still alive" "$(kill -0 "$LANE_PID" 2>/dev/null; echo $?)"

# ---- 1. one envelope -> result + claimed -------------------------------------
send "$(phase one)"
wait_for 15 results_at_least 1
r1="$(find "$LANE/inbox/results" -name '*.json' | head -1)"
check "envelope produced a result file" "$([ -n "$r1" ] && [ -f "$r1" ]; echo $?)"
check "result carries status ok and the reply" \
  "$(node -e 'const j=require(process.argv[1]); process.exit(j.status==="ok"&&j.value==="done one"&&j.id==="one"?0:1)' "$r1"; echo $?)"
check "envelope moved to claimed/" "$([ "$(ls "$LANE/inbox/claimed" | wc -l | tr -d ' ')" = 1 ]; echo $?)"
check "pending/ and active/ are empty" "$([ -z "$(ls -A "$LANE/inbox/pending")" ] && [ -z "$(ls -A "$LANE/inbox/active")" ]; echo $?)"
check "lane still alive after a phase" "$(kill -0 "$LANE_PID" 2>/dev/null; echo $?)"

# ---- 5. engine child did not inherit HQ_CONDUCT_RUN_DIR ----------------------
check "engine child sees HQ_CONDUCT_RUN_DIR unset" \
  "$([ "$(cat "$TMP/rec/conduct-env.one")" = '<unset>' ]; echo $?)"

# ---- 3. two envelopes queued while a phase runs -------------------------------
send "$(phase slow SLEEP=2)"
wait_for 10 grep -q ' slow$' "$TMP/rec/calls"
send "$(phase second)"
send "$(phase third)"
wait_for 20 results_at_least 4
order="$(awk '{print $2}' "$TMP/rec/calls" | tr '\n' ' ')"
check "all queued envelopes processed in arrival order ($order)" \
  "$([ "$order" = 'one slow second third ' ]; echo $?)"

# ---- 6b. failing phase -> error result, lane continues -------------------------
send "$(phase bad FAIL)"
wait_for 15 results_at_least 5
bad="$(grep -l '"id": "bad"' "$LANE/inbox/results"/*.json | head -1)"
check "failing phase writes an error result" \
  "$(node -e 'const j=require(process.argv[1]); process.exit(j.status==="error"?0:1)' "$bad"; echo $?)"
check "lane survives a failing phase" "$(kill -0 "$LANE_PID" 2>/dev/null; echo $?)"

# ---- 6c. malformed envelope and unwritable result_path: lane continues --------
send 'this is not json'
wait_for 15 results_at_least 6
check "malformed envelope writes an error result" \
  "$(grep -l 'unreadable envelope' "$LANE/inbox/results"/*.json >/dev/null 2>&1; echo $?)"
check "lane survives a malformed envelope" "$(kill -0 "$LANE_PID" 2>/dev/null; echo $?)"
send '{"kind":"phase","engine":"claude","tier":"exec","id":"badpath","prompt":"TAG=badpath","result_path":"/dev/null/nope/r.json"}'
wait_for 15 results_at_least 7
bp="$(grep -l '"id": "badpath"' "$LANE/inbox/results"/*.json 2>/dev/null | head -1)"
check "unwritable result_path falls back to results/ with the error noted" \
  "$([ -n "$bp" ] && grep -q result_path_error "$bp"; echo $?)"
check "lane survives an unwritable result_path" "$(kill -0 "$LANE_PID" 2>/dev/null; echo $?)"

# ---- 4. stop after the in-flight phase -----------------------------------------
send "$(phase last SLEEP=1)"
wait_for 10 grep -q ' last$' "$TMP/rec/calls"
send '{"kind":"stop"}'
wait "$LANE_PID"
rc=$?
LANE_PID=""
check "stop envelope: lane exits 0" "$([ $rc -eq 0 ]; echo $?)"
last="$(grep -l '"id": "last"' "$LANE/inbox/results"/*.json | head -1)"
check "in-flight phase finished before exit" \
  "$(node -e 'const j=require(process.argv[1]); process.exit(j.status==="ok"?0:1)' "$last"; echo $?)"
check "no envelope remains in pending/" "$([ -z "$(ls -A "$LANE/inbox/pending")" ]; echo $?)"
check "stop envelope is in claimed/" \
  "$([ "$(ls "$LANE/inbox/claimed" | wc -l | tr -d ' ')" = 9 ]; echo $?)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
