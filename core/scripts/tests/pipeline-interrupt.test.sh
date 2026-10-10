#!/usr/bin/env bash
# Tests for interrupted phases on a pipeline-driver.sh stop (bash 3.2 portable).
#
# Real pieces: pipeline-driver.sh, pipeline-conductor.sh, pipeline-envelope.sh.
# Stub: fake hq. Its lanes list returns the mapped loop lane and enqueue puts
# the envelope in the lane's pending queue, so a routed phase stays in flight
# (no lane runs it) until the test stops the driver.
#
# Each stop path marks the in-flight story `interrupted` (phase, time) and
# withdraws a queued envelope no lane picked up: driver/stop.json from
# `pipeline-conductor.sh stop` (exit 29), SIGTERM (143), SIGINT (130), and a
# loop lane that reports stopped after a stop envelope. A restarted
# driver routes interrupted stories first, before reopened ones, with
# resumed_after_interrupt in the envelope; TICK lines and FINAL list them
# until then.
# shellcheck disable=SC2016  # check() evals single-quoted assertions on purpose
set -u
unset HQ_SPAWN_COMPANY HQ_PARENT_SESSION_ID PC_NOW PC_MAX_STORIES PC_HQ
export HQ_SESSION_ID="test-pipeline-interrupt-$$"
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
DRIVER="$SCRIPTS/pipeline-driver.sh"
PC="$SCRIPTS/pipeline-conductor.sh"
PE="$SCRIPTS/pipeline-envelope.sh"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pipeline-interrupt.XXXXXX")" && pwd -P)"
DPID=""
trap '[ -n "$DPID" ] && kill -9 "$DPID" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
wait_for() { # wait_for <secs> <command...>
  limit=$(( $1 * 10 )); shift; i=0
  while [ $i -lt $limit ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
pyget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

mkdir -p "$T/hq/core/scripts" "$T/wt" "$T/workers/backend-dev" "$T/bin"
cat > "$T/hq/core/scripts/hq-session.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in current) printf 'test-session\n' ;; *company_slug*) printf 'indigo\n' ;; esac
EOF
chmod +x "$T/hq/core/scripts/hq-session.sh"
printf 'worker:\n  id: backend-dev\nverification:\n  approval_required: false\n' > "$T/workers/backend-dev/worker.yaml"
export PC_WORKERS_ROOT="$T/workers" PC_HQ_ROOT="$T/hq"
LANE="$T/lane"
cat > "$T/bin/hq" <<EOF
#!/usr/bin/env bash
set -eu
case "\$1 \$2" in
  'lanes create') printf '{"ok":true,"lane_id":"lane-backend-dev"}\\n' ;;
  'lanes enqueue')
    envfile=''; while [ \$# -gt 0 ]; do case "\$1" in --envelope) envfile="\$2"; shift 2;; *) shift;; esac; done
    mkdir -p "$LANE/inbox/pending"; cp "\$envfile" "$LANE/inbox/pending/\$(date +%s)-\$RANDOM.json"; printf '{"ok":true}\\n' ;;
  'lanes list')
    state=waiting; [ -f "$T/stopped" ] && state=stopped
    depth=0; for f in "$LANE"/inbox/pending/*.json; do [ -f "\$f" ] && depth=1; done
    project=\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$T/prd.json")
    printf '{"ok":true,"action":"list","lanes":[{"lane_id":"lane-backend-dev","company":{"slug":"indigo"},"project_id":"%s","worker":"backend-dev","loop":{"state":"%s","pid":1,"queue_depth":%s}}]}\\n' "\$project" "\$state" "\$depth" ;;
  'lanes interrupt')
    story=''; phase=''; while [ \$# -gt 0 ]; do case "\$1" in --story) story="\$2"; shift 2;; --phase) phase="\$2"; shift 2;; *) shift;; esac; done
    pending=''; for f in "$LANE"/inbox/pending/*.json; do [ -f "\$f" ] || continue; if jq -e --arg s "\$story" --arg p "\$phase" '.story_id == \$s and .phase == \$p' "\$f" >/dev/null; then pending="\$f"; break; fi; done
    if [ -n "\$pending" ]; then rm -f "\$pending"; printf '{"ok":true,"withdrawn":["%s-%s"],"already_picked_up":[]}\\n' "\$story" "\$phase"
    else printf '{"ok":true,"withdrawn":[],"already_picked_up":["%s-%s"]}\\n' "\$story" "\$phase"; fi ;;
  'lanes stop') touch "$T/stopped"; printf '{"ok":true}\\n' ;;
  *) printf '{"ok":false,"error":"unexpected_call"}\\n'; exit 1 ;;
esac
EOF
chmod +x "$T/bin/hq"
export PC_HQ="$T/bin/hq" PATH="$T/bin:$PATH"
cat > "$T/prd.json" <<'EOF'
{"name":"idemo","userStories":[
 {"id":"S1","title":"one","priority":1,"passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["a"]}
]}
EOF

# start_driver: the driver in the background with SIGINT at its default, so its INT trap can be set
start_driver() {
  python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    sh "$DRIVER" --prd "$T/prd.json" --state "$S" --worktree "$T/wt" --interval 0.2 --stall-window 3600 >/dev/null 2>&1 &
  DPID=$!
}
fresh() { # fresh <name>: a new state dir and an empty lane, the driver started, S1 routed
  S="$T/$1"; rm -rf "$LANE"; mkdir -p "$LANE/inbox/pending" "$LANE/inbox/active" "$S"
  start_driver
  wait_for 20 grep -qs "ROUTED S1 backend" "$S/driver/driver.log"
}
code() { cut -d' ' -f1 "$S/driver/exit" 2>/dev/null; }
pending_has() { grep -qs "\"$1\"" "$LANE"/inbox/pending/*.json; }

# ---- stop.json through pipeline-conductor.sh stop ----
fresh stopjson
check "stop.json: S1 routed and its envelope queued, unpicked" '[ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = in_flight ] && pending_has S1'
"$PC" stop --state "$S" --note "owner stop" > "$T/stop.out" 2>&1
wait_for 20 test -f "$S/driver/exit"
check "stop.json: the driver exits 29 stopped on request and removes stop.json" \
  '[ "$(code)" = 29 ] && grep -q "stopped on request" "$S/driver/exit" && [ ! -f "$S/driver/stop.json" ]'
check "stop.json: S1 interrupted at backend with a time" \
  '[ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = interrupted ] && [ "$(pyget "$S/stories/S1.json" "d[\"interrupted\"][\"phase\"]")" = backend ] && [ -n "$(pyget "$S/stories/S1.json" "d[\"interrupted\"][\"at\"]")" ]'
check "stop.json: the unpicked envelope is withdrawn from the lane queue" \
  '! pending_has S1 && [ "$(pyget "$S/stories/S1.json" "d[\"interrupted\"][\"withdrawn\"]")" = True ] && grep -q "INTERRUPT rc=0: INTERRUPTED S1 backend withdrawn" "$S/driver/driver.log"'
"$PC" report final --state "$S" > "$T/final.out" 2>&1
check "stop.json: the all-done summary lists the interrupted story" 'grep -q "interrupted 1,.*routed first on the next driver start: S1 at backend" "$T/final.out"'
# restart: S1 is routed first, at backend, with resumed_after_interrupt
start_driver
wait_for 20 grep -q "INTERRUPTED_FIRST S1@backend" "$S/driver/driver.log"
wait_for 20 eval '[ "$(grep -c "ROUTED S1 backend" "$S/driver/driver.log")" = 2 ]'
check "restart: START names the interrupted story and the TICK line lists it" \
  'grep -q "INTERRUPTED_FIRST S1@backend" "$S/driver/driver.log" && grep " TICK: " "$S/driver/driver.log" | grep -q "interrupted, routing first: S1 at backend"'
check "restart: S1 routed again at backend with resumed_after_interrupt, envelope valid" \
  '[ "$(pyget "$S/envelopes/S1-backend.json" "d[\"resumed_after_interrupt\"]")" = True ] && "$PE" validate --kind envelope "$S/envelopes/S1-backend.json" >/dev/null 2>&1 && pending_has S1'
kill -9 "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=""

# ---- SIGTERM, envelope already picked up by the lane ----
fresh term
for f in "$LANE"/inbox/pending/*.json; do mv "$f" "$LANE/inbox/active/"; done
kill -TERM "$DPID"; wait_for 20 test -f "$S/driver/exit"; wait "$DPID" 2>/dev/null; DPID=""
check "SIGTERM: exit 143, S1 interrupted at backend" \
  '[ "$(code)" = 143 ] && [ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = interrupted ] && [ "$(pyget "$S/stories/S1.json" "d[\"interrupted\"][\"phase\"]")" = backend ]'
check "SIGTERM: an envelope the lane picked up is left alone" \
  '[ "$(pyget "$S/stories/S1.json" "d[\"interrupted\"][\"withdrawn\"]")" = False ] && grep -qs "\"S1\"" "$LANE"/inbox/active/*.json'

# ---- SIGINT ----
fresh int
kill -INT "$DPID"; wait_for 20 test -f "$S/driver/exit"; wait "$DPID" 2>/dev/null; DPID=""
check "SIGINT: exit 130, S1 interrupted, envelope withdrawn" \
  '[ "$(code)" = 130 ] && [ "$(pyget "$S/stories/S1.json" "d[\"state\"]")" = interrupted ] && ! pending_has S1'

# ---- a loop lane that exited on a stop envelope ----
fresh lanestop
for f in "$LANE"/inbox/pending/*.json; do mv "$f" "$LANE/inbox/active/"; done
printf '{"ts":"%s","event":"loop-done","processed":1}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LANE/journal.jsonl"
touch "$T/stopped"
wait_for 20 grep -q "LANE_STOPPED S1 backend" "$S/driver/driver.log"
wait_for 20 eval '[ "$(grep -c "ROUTED S1 backend" "$S/driver/driver.log")" = 2 ]'
check "lane stop envelope: the driver marks S1 interrupted" \
  'grep -q "LANE_STOPPED S1 backend rc=0: INTERRUPTED S1 backend" "$S/driver/driver.log" && [ "$(pyget "$S/stories/S1.json" "d[\"interrupted\"][\"phase\"]")" = backend ]'
check "lane stop envelope: S1 is routed again with resumed_after_interrupt" \
  '[ "$(pyget "$S/envelopes/S1-backend.json" "d[\"resumed_after_interrupt\"]")" = True ]'
kill -9 "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=""

# ---- interrupted before reopened ----
cat > "$T/prd.json" <<'EOF'
{"name":"idemo","userStories":[
 {"id":"S1","title":"one","priority":1,"passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["a"]},
 {"id":"S9","title":"nine","priority":9,"passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["b"]}
]}
EOF
S="$T/order"; rm -rf "$LANE"; mkdir -p "$S/stories" "$LANE/inbox/pending"
printf '{"id":"S1","title":"one","phases":[{"phase":"backend","worker":"backend-dev"}],"current":0,"state":"queued","reroutes":0,"worktree":"%s","started":true,"reopen":{"index":0,"phase":"backend","note":"gate failed","at":"2026-01-01T00:00:00Z","from":"verified"}}\n' "$T/wt" > "$S/stories/S1.json"
printf '{"id":"S9","title":"nine","phases":[{"phase":"backend","worker":"backend-dev"}],"current":0,"state":"interrupted","reroutes":0,"worktree":"%s","started":true,"interrupted":{"phase":"backend","index":0,"worker":"backend-dev","at":"2026-01-01T00:00:00Z","reason":"terminated","withdrawn":true}}\n' "$T/wt" > "$S/stories/S9.json"
start_driver
wait_for 20 eval 'grep -qs "ROUTED S1 backend" "$S/driver/driver.log" && grep -qs "ROUTED S9 backend" "$S/driver/driver.log"'
kill -9 "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=""
check "order: START lists the interrupted story and the reopened one" \
  'grep -q "INTERRUPTED_FIRST S9@backend" "$S/driver/driver.log" && grep -q "REOPENED_FIRST S1@backend" "$S/driver/driver.log"'
check "order: the interrupted story is routed before the reopened one" \
  'grep " TICK: " "$S/driver/driver.log" | head -1 | grep -q "ROUTED S9 backend.*ROUTED S1 backend"'
check "order: only the interrupted story's envelope says resumed_after_interrupt" \
  '[ "$(pyget "$S/envelopes/S9-backend.json" "d.get(\"resumed_after_interrupt\")")" = True ] && [ "$(pyget "$S/envelopes/S1-backend.json" "d.get(\"resumed_after_interrupt\")")" = None ] && [ -n "$(pyget "$S/envelopes/S1-backend.json" "d[\"reopen_note\"]")" ]'

check "driver stays dash -n and sh -n clean" 'sh -n "$DRIVER" && { ! command -v dash >/dev/null || dash -n "$DRIVER"; }'
echo "pipeline-interrupt: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
