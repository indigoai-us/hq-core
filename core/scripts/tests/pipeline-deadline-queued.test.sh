#!/usr/bin/env bash
# pipeline-driver.sh: the envelope deadline bounds work, not queue time.
#
# Case 1: the deadline has passed but the envelope still waits in its lane's
#   queue (the lane is throttle-queued or busy; active_envelope_id is not this
#   envelope) -> no DEADLINE, no exit 22, the story stays in flight.
# Case 2: the deadline has passed and the lane is working this envelope
#   (active_envelope_id == envelope id) -> exit 22 as before.
# Case 3: the deadline has passed and hq lanes list has no row for the lane
#   (the lane is gone) -> exit 22 as before; a missing row is not "queued".
# Case 4: the envelope waits in the queue past its deadline, then the lane
#   picks it up -> no exit 22 right at pickup; the phase gets its full budget
#   (deadline minus routing time) from the last time it was seen queued, and
#   exits 22 once that runs out.
# bash 3.2 portable.
set -u
unset HQ_SPAWN_COMPANY HQ_PARENT_SESSION_ID HQ_PIPELINE_DECISIONS_FILE HQ_WORKFLOW_LANE \
  CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID \
  PC_WORKERS_ROOT PC_HQ PC_ENVELOPE PC_NOW PC_MAX_STORIES
export HQ_SESSION_ID="test-pipeline-deadline-queued-$$"

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
DRIVER="${PIPELINE_DEADLINE_DRIVER:-$SCRIPTS/pipeline-driver.sh}"

pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
wait_for() { limit=$(( $1 * 10 )); shift; i=0; while [ $i -lt $limit ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pipeline-deadline.XXXXXX")" && pwd -P)"
DPIDS=""
cleanup() {
  for p in $DPIDS; do kill "$p" 2>/dev/null; done
  for p in $DPIDS; do wait "$p" 2>/dev/null; done
  [ -n "${KEEP:-}" ] || rm -rf "$T"
}
trap cleanup EXIT
export HQ_ROOT="$T/hq" PC_HQ_ROOT="$T/hq"
mkdir -p "$HQ_ROOT/workspace/sessions"

rows_for() { # rows_for <active_envelope_id or empty>: hq lanes list --json for the lane
  if [ -n "$1" ]; then active="\"$1\""; else active=null; fi
  printf '[{"lane_id":"lane-backend-dev","state":"queued","loop":{"state":"waiting","queue_depth":1,"active_envelope_id":%s,"pid":1}}]\n' "$active"
}
iso_ago() { # iso_ago <seconds>: UTC timestamp that many seconds in the past
  node -e 'process.stdout.write(new Date(Date.now() - Number(process.argv[1]) * 1000).toISOString().slice(0, 19) + "Z")' "$1"
}

setup() { # setup <name> <active_envelope_id or empty> [nolane] [deadline]
  C="$T/$1"; S="$C/state"
  mkdir -p "$S/stories" "$S/envelopes" "$S/handoffs" "$S/driver"
  cat > "$C/prd.json" <<'EOF'
{"name":"deadline","userStories":[{"id":"S1","title":"t","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["a"]}]}
EOF
  printf '{"id":"S1","title":"t","phases":[{"phase":"backend","worker":"backend-dev"}],"current":0,"state":"in_flight","reroutes":0,"worktree":"%s","started":true,"routed_at":%s}\n' \
    "$C" "$(( $(date +%s) - 30 ))" > "$S/stories/S1.json"
  printf '{"id":"S1-backend.r1","deadline":"%s"}\n' "${4:-2000-01-01T00:00:00Z}" > "$S/envelopes/S1-backend.json"
  printf '{"backend-dev":"lane-backend-dev"}\n' > "$S/lanes.json"
  if [ "${3:-}" = nolane ]; then printf '[]\n' > "$C/rows.json"; else rows_for "$2" > "$C/rows.json"; fi
  mkdir -p "$C/bin" "$HQ_ROOT/core/scripts"
  cat > "$HQ_ROOT/core/scripts/hq-session.sh" <<'SESSION'
#!/usr/bin/env bash
case "$*" in current) printf 'test-session\n' ;; *company_slug*) printf 'indigo\n' ;; esac
SESSION
  chmod +x "$HQ_ROOT/core/scripts/hq-session.sh"
  cat > "$C/bin/hq" <<EOF
#!/bin/sh
case "\$1" in
  lanes)
    case "\$2" in
      list) cat "$C/rows.json" ;;
      stop) printf '[]\n' > "$C/rows.json"; printf '{"ok":true}\n' ;;
      interrupt|questions) printf '{"ok":true,"withdrawn":[],"already_picked_up":[]}\n' ;;
      *) printf '{"ok":true}\n' ;;
    esac ;;
  *) : ;;
esac
EOF
  chmod +x "$C/bin/hq"
}
start_driver() {
  PC_HQ="$C/bin/hq" PC_WORKERS_ROOT="$T/workers" sh "$DRIVER" --prd "$C/prd.json" --state "$S" \
    --interval 0.2 --stall-window 3600 >/dev/null 2>&1 &
  DPID=$!; DPIDS="$DPIDS $DPID"
}
stop_driver() { kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; }
exit_code() { [ -f "$S/driver/exit" ] && cut -d' ' -f1 "$S/driver/exit"; }

# ---- case 1: past deadline, still queued -----------------------------------
setup queued ""
start_driver
sleep 3
check "1: a queued envelope past its deadline does not exit 22" \
  '[ ! -f "$S/driver/exit" ] && ! grep -q "passed its deadline" "$S/driver/driver.log"'
stop_driver

# ---- case 2: past deadline, lane working it ---------------------------------
setup active "S1-backend.r1"
start_driver
wait_for 20 test -f "$S/driver/exit"
check "2: an active envelope past its deadline exits 22" \
  '[ "$(exit_code)" = 22 ] && grep -q "S1/backend passed its deadline" "$S/driver/exit"'
stop_driver

# ---- case 3: past deadline, no lane row --------------------------------------
setup nolane "" nolane
start_driver
wait_for 20 test -f "$S/driver/exit"
check "3: a past-deadline envelope whose lane has no row still exits 22" \
  '[ "$(exit_code)" = 22 ] && grep -q "S1/backend passed its deadline" "$S/driver/exit"'
stop_driver

# ---- case 4: waited in the queue past the deadline, then picked up ----------
# routed 30s ago with a 10s budget, so the stamped deadline is 20s in the past
setup pickup "" "" "$(iso_ago 20)"
start_driver
sleep 3
rows_for "S1-backend.r1" > "$C/rows.json"
sleep 3
check "4a: no exit 22 right after a long-queued envelope is picked up" \
  '[ ! -f "$S/driver/exit" ] && ! grep -q "passed its deadline" "$S/driver/driver.log"'
wait_for 30 test -f "$S/driver/exit"
check "4b: the picked-up envelope exits 22 once its own budget runs out" \
  '[ "$(exit_code)" = 22 ] && grep -q "S1/backend passed its deadline" "$S/driver/exit"'
stop_driver

echo "pipeline-deadline-queued: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
