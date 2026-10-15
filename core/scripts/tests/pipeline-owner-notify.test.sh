#!/usr/bin/env bash
# hq-core: public
# pipeline-driver.sh: a stop that needs the owner is announced, not left in a file.
#
# The driver's only report used to be {state}/driver/exit plus decisions/*.md, so a
# run that stopped for a decision stayed silent until someone looked. The driver
# now enqueues a Work Mesh "blocked" signal for the session when it exits with a
# code the owner or parent must act on.
#
# Case 1: a phase hands back status blocked -> exit 21, and one
#   `hq mesh session blocked --enqueue` call names the session, the exit code and
#   the reason.
# Case 2: a requested stop (exit 29) is not announced: the owner asked for it.
# Case 3: no HQ_SESSION_ID -> exit 21 still happens, no mesh call, and the log
#   says why the announcement was skipped.
# bash 3.2 portable.
set -u
unset HQ_SPAWN_COMPANY HQ_PARENT_SESSION_ID HQ_PIPELINE_DECISIONS_FILE HQ_WORKFLOW_LANE \
  CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID \
  PC_WORKERS_ROOT PC_HQ PC_ENVELOPE PC_NOW PC_MAX_STORIES
SID="test-pipeline-owner-notify-$$"
export HQ_SESSION_ID="$SID"

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
DRIVER="${PIPELINE_NOTIFY_DRIVER:-$SCRIPTS/pipeline-driver.sh}"

pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
wait_for() { limit=$(( $1 * 10 )); shift; i=0; while [ $i -lt $limit ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pipeline-notify.XXXXXX")" && pwd -P)"
DPIDS=""
cleanup() {
  for p in $DPIDS; do kill "$p" 2>/dev/null; done
  [ -n "${KEEP:-}" ] || rm -rf "$T"
}
trap cleanup EXIT
export HQ_ROOT="$T/hq" PC_HQ_ROOT="$T/hq"
mkdir -p "$HQ_ROOT/workspace/sessions"

setup() { # setup <name>
  C="$T/$1"; S="$C/state"
  mkdir -p "$S/stories" "$S/envelopes" "$S/handoffs" "$S/driver"
  cat > "$C/prd.json" <<'EOF'
{"name":"notify","userStories":[{"id":"S1","title":"t","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["a"]}]}
EOF
  printf '{"id":"S1","title":"t","phases":[{"phase":"backend","worker":"backend-dev"}],"current":0,"state":"in_flight","reroutes":0,"worktree":"%s","started":true,"routed_at":%s}\n' \
    "$C" "$(( $(date +%s) - 30 ))" > "$S/stories/S1.json"
  printf '{"deadline":"2999-01-01T00:00:00Z"}\n' > "$S/envelopes/S1-backend.json"
  mkdir -p "$T/bin" "$HQ_ROOT/core/scripts"
  cat > "$HQ_ROOT/core/scripts/hq-session.sh" <<'SESSION'
#!/usr/bin/env bash
case "$*" in current) printf 'test-session\n' ;; *company_slug*) printf 'acme\n' ;; esac
SESSION
  chmod +x "$HQ_ROOT/core/scripts/hq-session.sh"
  cat > "$T/bin/hq" <<EOF
#!/bin/sh
case "\$1" in
  mesh) printf '%s\n' "\$*" >> "$C/mesh-calls"; printf '{"ok":true}\n' ;;
  lanes)
    case "\$2" in
      create|enqueue) printf '{"ok":true,"lane_id":"lane-backend-dev"}\n' ;;
      list) printf '[]\n' ;;
      *) printf '{"ok":true,"withdrawn":[],"already_picked_up":[]}\n' ;;
    esac ;;
  *) : ;;
esac
EOF
  chmod +x "$T/bin/hq"
}
blocked_handoff() {
  printf '{"schema":"hq-phase-handoff/v1","story_id":"S1","phase":"backend","worker_id":"backend-dev","status":"blocked","summary":"two failing tests on main are outside this story","notes":"parent call needed","files_changed":[],"commits":[],"back_pressure":{"tests":"fail","lint":"skip","typecheck":"skip","build":"skip"},"context_for_next":"decide"}\n' > "$S/handoffs/S1-backend.json"
}
start_driver() {
  PC_HQ="$T/bin/hq" PC_WORKERS_ROOT="$T/workers" sh "$DRIVER" --prd "$C/prd.json" --state "$S" \
    --interval 0.2 >/dev/null 2>&1 &
  DPID=$!; DPIDS="$DPIDS $DPID"
}
exit_code() { [ -f "$S/driver/exit" ] && cut -d' ' -f1 "$S/driver/exit"; }

# ---- case 1: held for the owner -> announced ---------------------------------
setup one
blocked_handoff
start_driver
wait_for 20 test -f "$S/driver/exit"
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
check "1: the driver exits 21 for a blocked phase" '[ "$(exit_code)" = 21 ]'
check "1: exactly one mesh blocked signal was enqueued" \
  '[ "$(grep -c "^mesh session blocked --enqueue" "$C/mesh-calls" 2>/dev/null)" = 1 ]'
check "1: the signal names the session, the exit code and the reason" \
  'grep -q -- "--session-id $SID" "$C/mesh-calls" && grep -q -- "--reason pipeline driver stopped (exit 21)" "$C/mesh-calls" && grep -q "outside this story" "$C/mesh-calls"'
check "1: the summary points at the decision file" \
  'grep -q -- "--summary .*$S/decisions" "$C/mesh-calls"'
check "1: the log records the announcement" 'grep -q "NOTIFY exit=21 mesh blocked rc=0" "$S/driver/driver.log"'

# ---- case 2: a requested stop is not announced ---------------------------------
setup two
start_driver
# a stop.json present at start is stale and removed, so write it once the driver runs
wait_for 20 grep -qs "TICK" "$S/driver/driver.log"
printf '{"kind":"stop","note":"owner asked"}\n' > "$S/driver/stop.json"
wait_for 20 test -f "$S/driver/exit"
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
check "2: the driver exits 29 on a stop request" '[ "$(exit_code)" = 29 ]'
check "2: no mesh signal for a stop the owner asked for" '[ ! -s "$C/mesh-calls" ]'

# ---- case 3: no session id -> no signal, but the log says so -------------------
setup three
blocked_handoff
HQ_SESSION_ID= start_driver
wait_for 20 test -f "$S/driver/exit"
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
check "3: exit 21 still happens without a session id" '[ "$(exit_code)" = 21 ]'
check "3: no mesh call without a session id" '[ ! -s "$C/mesh-calls" ]'
check "3: the log says the announcement was skipped and why" \
  'grep -q "NOTIFY exit=21 skipped: no HQ_SESSION_ID" "$S/driver/driver.log"'

echo "pipeline-owner-notify: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
