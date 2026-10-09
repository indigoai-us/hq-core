#!/usr/bin/env bash
# SessionStart keeps context-producing checks bounded and runs maintenance in
# the background with a single-flight lock and an independent wall-clock cap.
set -uo pipefail

SRC="${C179B_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)}"
TMP="$(mktemp -d)"
FIX="$TMP/fixture"
BIN="$TMP/bin"
HOME_DIR="$TMP/home"
NODE_BIN="$(command -v node 2>/dev/null || true)"
[ -n "$NODE_BIN" ] || { echo "FAIL: node is required for the bounded hq runner test" >&2; exit 1; }
NODE_DIR="${NODE_BIN%/*}"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/hooks/SessionStart" "$FIX/companies/indigo/hooks/SessionStart" \
  "$FIX/core/scripts/lib" "$FIX/workspace/sessions" "$FIX/tmp" \
  "$BIN" "$HOME_DIR"
FAIL=0
MESH_PID_FILE="$TMP/mesh.pid"
MESH_CHILD_PID_FILE="$TMP/mesh-child.pid"
MESH_STARTED="$TMP/mesh.started"
MESH_DONE="$TMP/mesh.done"
MESH_INVOCATIONS="$TMP/mesh.invocations"
MESH_OBSERVATIONS="$TMP/mesh.observations"
MESH_RECORD_LOG="$TMP/mesh.record-log"
MESH_RELEASE_FIRST="$TMP/mesh.release-first"
RECONCILE_WORKERS="$TMP/reconcile-workers"
SIGNAL_NODE_PID_FILE="$TMP/signal-node.pid"
SIGNAL_CHILD_STARTED="$TMP/signal-child.started"
SIGNAL_CHILD_STOPPED="$TMP/signal-child.stopped"
SIGNAL_CHILD_PID_FILE="$TMP/signal-child.pid"
SIGNAL_CHILD_PGID_FILE="$TMP/signal-child.pgid"
LARGE_STDOUT="$TMP/large.stdout"
LARGE_STDERR="$TMP/large.stderr"
LANES_PID_FILE="$TMP/lanes.pid"
LANES_CHILD_PID_FILE="$TMP/lanes-child.pid"
LANES_STARTED="$TMP/lanes.started"
LANES_DONE="$TMP/lanes.done"
REGISTER_PID_FILE="$TMP/register.pid"
REGISTER_CHILD_PID_FILE="$TMP/register-child.pid"
REGISTER_STARTED="$TMP/register.started"
REGISTER_DONE="$TMP/register.done"
MESH_PGID_FILE="$TMP/mesh.pgid"
LANES_PGID_FILE="$TMP/lanes.pgid"
REGISTER_PGID_FILE="$TMP/register.pgid"
PREFLIGHT_PID_FILE="$TMP/preflight.pid"
PREFLIGHT_CHILD_PID_FILE="$TMP/preflight-child.pid"
PREFLIGHT_STARTED="$TMP/preflight.started"
PREFLIGHT_DONE="$TMP/preflight.done"
PREFLIGHT_PGID_FILE="$TMP/preflight.pgid"
PREFLIGHT_NO_UPDATE_FILE="$TMP/preflight-no-update"
VALID_PREFLIGHT_READY="$TMP/valid-preflight.ready"
REPAIR_PID_FILE="$TMP/repair.pid"
REPAIR_CHILD_PID_FILE="$TMP/repair-child.pid"
REPAIR_STARTED="$TMP/repair.started"
REPAIR_DONE="$TMP/repair.done"
REPAIR_PGID_FILE="$TMP/repair.pgid"
REPAIR_NO_UPDATE_FILE="$TMP/repair-no-update"
TEST_MAIN_PGID="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')"

pass() { printf '  ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
cleanup() {
  local pid pgid args
  # session_auto_bind_run_with_timeout uses Node's detached spawn, which creates
  # a process group. Signal that group before deleting the test fixture.
  for group_file in "$MESH_PGID_FILE" "$LANES_PGID_FILE" "$REGISTER_PGID_FILE" \
    "$PREFLIGHT_PGID_FILE" "$REPAIR_PGID_FILE" "$SIGNAL_CHILD_PGID_FILE"; do
    [ -f "$group_file" ] || continue
    while IFS= read -r pgid; do
      [[ "$pgid" =~ ^[0-9]+$ ]] && [ "$pgid" -gt 1 ] && [ "$pgid" != "$TEST_MAIN_PGID" ] \
        && kill -TERM -- "-$pgid" 2>/dev/null || true
    done < "$group_file"
  done
  for pid_file in "$MESH_PID_FILE" "$MESH_CHILD_PID_FILE" "$LANES_PID_FILE" "$LANES_CHILD_PID_FILE" \
    "$REGISTER_PID_FILE" "$REGISTER_CHILD_PID_FILE" "$PREFLIGHT_PID_FILE" "$PREFLIGHT_CHILD_PID_FILE" \
    "$REPAIR_PID_FILE" "$REPAIR_CHILD_PID_FILE"; do
    [ -f "$pid_file" ] || continue
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && kill -TERM "$pid" 2>/dev/null || true
    done < "$pid_file"
  done
  for pid_file in "$TMP"/*-locks/*/pid; do
    [ -f "$pid_file" ] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    args="$(ps -ww -p "$pid" -o args= 2>/dev/null || true)"
    case "$args" in *"$TMP"*) kill -TERM "$pid" 2>/dev/null || true ;; esac
  done
  sleep 0.1
  for group_file in "$MESH_PGID_FILE" "$LANES_PGID_FILE" "$REGISTER_PGID_FILE" \
    "$PREFLIGHT_PGID_FILE" "$REPAIR_PGID_FILE" "$SIGNAL_CHILD_PGID_FILE"; do
    [ -f "$group_file" ] || continue
    while IFS= read -r pgid; do
      [[ "$pgid" =~ ^[0-9]+$ ]] && [ "$pgid" -gt 1 ] && [ "$pgid" != "$TEST_MAIN_PGID" ] \
        && kill -KILL -- "-$pgid" 2>/dev/null || true
    done < "$group_file"
  done
  for pid_file in "$MESH_PID_FILE" "$MESH_CHILD_PID_FILE" "$LANES_PID_FILE" "$LANES_CHILD_PID_FILE" \
    "$REGISTER_PID_FILE" "$REGISTER_CHILD_PID_FILE" "$PREFLIGHT_PID_FILE" "$PREFLIGHT_CHILD_PID_FILE" \
    "$REPAIR_PID_FILE" "$REPAIR_CHILD_PID_FILE"; do
    [ -f "$pid_file" ] || continue
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && kill -KILL "$pid" 2>/dev/null || true
    done < "$pid_file"
  done
  for pid_file in "$TMP"/*-locks/*/pid; do
    [ -f "$pid_file" ] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    args="$(ps -ww -p "$pid" -o args= 2>/dev/null || true)"
    case "$args" in *"$TMP"*) kill -KILL "$pid" 2>/dev/null || true ;; esac
  done
  if [ -f "$RECONCILE_WORKERS" ]; then
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      args="$(ps -ww -p "$pid" -o args= 2>/dev/null || true)"
      case "$args" in *"$TMP"*) kill -TERM "$pid" 2>/dev/null || true ;; esac
    done < "$RECONCILE_WORKERS"
  fi
  for pid_file in "$SIGNAL_NODE_PID_FILE" "$SIGNAL_CHILD_PID_FILE"; do
    [ -f "$pid_file" ] || continue
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      args="$(ps -ww -p "$pid" -o args= 2>/dev/null || true)"
      case "$args" in *"$TMP"*) kill -TERM "$pid" 2>/dev/null || true ;; esac
    done < "$pid_file"
  done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

safe_env() {
  env -i PATH="$BIN:$NODE_DIR:/usr/local/bin:/usr/bin:/bin" HOME="$HOME_DIR" TMPDIR="$FIX/tmp" \
    AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_CONFIG_FILE=/dev/null \
    AWS_EC2_METADATA_DISABLED=true "$@"
}

now_ms() {
  node -e 'process.stdout.write(String(Number(process.hrtime.bigint() / 1000000n)))'
}

cp "$SRC/.claude/hooks/master-hook.sh" "$FIX/.claude/hooks/master-hook.sh"
cp "$SRC/.claude/hooks/hook-timeout-probe.sh" "$FIX/.claude/hooks/hook-timeout-probe.sh"
cp "$SRC/.claude/hooks/hook-gate.sh" "$FIX/.claude/hooks/hook-gate.sh"
cp "$SRC/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/hook-adapter-core.sh"
cp -R "$SRC/core/scripts/lib/." "$FIX/core/scripts/lib/"
cp "$SRC/core/hooks/SessionStart/35-work-mesh-session-start.sh" \
  "$FIX/core/hooks/SessionStart/35-work-mesh-session-start.sh"
cp "$SRC/core/hooks/SessionStart/45-lanes-senior-monitor.sh" \
  "$FIX/core/hooks/SessionStart/45-lanes-senior-monitor.sh"
cp "$SRC/core/hooks/SessionStart/preflight-fixtures.json" \
  "$FIX/core/hooks/SessionStart/preflight-fixtures.json"
chmod +x "$FIX/.claude/hooks/master-hook.sh" \
  "$FIX/core/hooks/SessionStart/35-work-mesh-session-start.sh" \
  "$FIX/core/hooks/SessionStart/45-lanes-senior-monitor.sh"
cat > "$FIX/core/scripts/register-project.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$TEST_REGISTER_PID_FILE"
ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]' >> "$TEST_REGISTER_PGID_FILE"
printf '%s\n' started > "$TEST_REGISTER_STARTED"
trap 'printf "%s\\n" stopped > "$TEST_REGISTER_DONE"; exit 0' TERM INT
sleep 30 & child=$!
printf '%s\n' "$child" >> "$TEST_REGISTER_CHILD_PID_FILE"
wait "$child"
printf '%s\n' completed > "$TEST_REGISTER_DONE"
SH
chmod +x "$FIX/core/scripts/register-project.sh"
jq -n '{hooks:{}}' > "$FIX/.claude/hooks/hook-registry.json"
cat > "$BIN/qmd" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN/qmd"

cat > "$BIN/hq" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}:${2:-}" in
  mesh:context)
    if [ "${3:-}" = default ] && [ "${4:-}" = get ]; then
      if [ -f "$TEST_VALID_PREFLIGHT_READY" ] && [ "${TEST_REPAIR_MODE:-fast}" = slow ]; then
        printf '%s\n' "${HQ_NO_UPDATE_CHECK:-}" >> "$TEST_REPAIR_NO_UPDATE_FILE"
        printf '%s\n' "$$" >> "$TEST_REPAIR_PID_FILE"
        ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]' >> "$TEST_REPAIR_PGID_FILE"
        printf '%s\n' started > "$TEST_REPAIR_STARTED"
        trap 'printf "%s\\n" stopped > "$TEST_REPAIR_DONE"; exit 0' TERM INT
        sleep 30 & child=$!
        printf '%s\n' "$child" >> "$TEST_REPAIR_CHILD_PID_FILE"
        wait "$child"
        printf '%s\n' completed > "$TEST_REPAIR_DONE"
      fi
      printf '%s\n' '{}'
      exit 0
    fi
    if [ "${3:-}" != reconcile ]; then
      printf '%s\n' '{}'
      exit 0
    fi
    observation=""
    previous=""
    offline=0
    for current in "$@"; do
      [ "$previous" != --observation-file ] || observation="$current"
      [ "$current" != --offline ] || offline=1
      previous="$current"
    done
    if [ "$offline" -eq 1 ]; then
      if [ "${TEST_PREFLIGHT_MODE:-fast}" = slow ]; then
        printf '%s\n' "${HQ_NO_UPDATE_CHECK:-}" > "$TEST_PREFLIGHT_NO_UPDATE_FILE"
        printf '%s\n' "$$" >> "$TEST_PREFLIGHT_PID_FILE"
        ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]' >> "$TEST_PREFLIGHT_PGID_FILE"
        printf '%s\n' started > "$TEST_PREFLIGHT_STARTED"
        trap 'printf "%s\\n" stopped > "$TEST_PREFLIGHT_DONE"; exit 0' TERM INT
        sleep 30 & child=$!
        printf '%s\n' "$child" >> "$TEST_PREFLIGHT_CHILD_PID_FILE"
        wait "$child"
        printf '%s\n' completed > "$TEST_PREFLIGHT_DONE"
      elif [ "${TEST_PREFLIGHT_MODE:-fast}" = valid ]; then
        session_id="$(jq -er '.sessionId' "$observation")"
        operation_id="$(jq -er '.clientOperationId' "$observation")"
        printf '%s\n' ready > "$TEST_VALID_PREFLIGHT_READY"
        jq -cn --arg sid "$session_id" --arg op "$operation_id" \
          '{contractVersion:1,kind:"bound",classification:"bound",delivery:"clean",lifecycle:"open",sessionId:$sid,clientOperationId:$op,companySlug:"indigo",companyUid:"cmp_indigo"}'
        exit 0
      fi
      printf '%s\n' '{}'
      exit 0
    fi
    if [ "${TEST_MESH_MODE:-slow}" = sequence ]; then
      cwd="$(jq -er '.cwd' "$observation")"
      phase=before-release
      [ ! -f "$TEST_MESH_RELEASE_FIRST" ] || phase=after-release
      printf '%s|%s\n' "$cwd" "$phase" >> "$TEST_MESH_OBSERVATIONS"
      if [ "$(wc -l < "$TEST_MESH_OBSERVATIONS")" -eq 1 ]; then
        printf '%s\n' started > "$TEST_MESH_STARTED"
        while [ ! -f "$TEST_MESH_RELEASE_FIRST" ]; do sleep 0.02; done
      fi
      exit 0
    fi
    if [ "${TEST_MESH_MODE:-slow}" = record ]; then
      jq -er '.cwd' "$observation" >> "$TEST_MESH_RECORD_LOG"
      exit 0
    fi
    if [ "${TEST_MESH_MODE:-slow}" = fast ]; then
      printf '%s\n' '{}'
      exit 0
    fi
    if [ "${TEST_MESH_MODE:-slow}" = after-five ]; then
      printf '%s\n' "$$" >> "$TEST_MESH_PID_FILE"
      printf '%s\n' started > "$TEST_MESH_STARTED"
      trap 'printf "%s\\n" stopped > "$TEST_MESH_DONE"; exit 0' TERM INT
      sleep 6
      printf '%s\n' completed > "$TEST_MESH_DONE"
      exit 0
    fi
    printf 'run\n' >> "$TEST_MESH_INVOCATIONS"
    printf '%s\n' "$$" >> "$TEST_MESH_PID_FILE"
    ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]' >> "$TEST_MESH_PGID_FILE"
    printf '%s\n' started > "$TEST_MESH_STARTED"
    trap 'printf "%s\\n" stopped > "$TEST_MESH_DONE"; exit 0' TERM INT
    sleep 30 & child=$!
    printf '%s\n' "$child" >> "$TEST_MESH_CHILD_PID_FILE"
    wait "$child"
    printf '%s\n' completed > "$TEST_MESH_DONE"
    exit 0
    ;;
  lanes:monitor-check)
    if [ "${TEST_LANES_MODE:-fast}" = slow ]; then
      printf '%s\n' "$$" >> "$TEST_LANES_PID_FILE"
      ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]' >> "$TEST_LANES_PGID_FILE"
      printf '%s\n' started > "$TEST_LANES_STARTED"
      trap 'printf "%s\\n" stopped > "$TEST_LANES_DONE"; exit 0' TERM INT
      sleep 30 & child=$!
      printf '%s\n' "$child" >> "$TEST_LANES_CHILD_PID_FILE"
      wait "$child"
      printf '%s\n' completed > "$TEST_LANES_DONE"
      printf '%s\n' late-context
      exit 0
    fi
    session=""
    engine=claude
    previous=""
    for current in "$@"; do
      [ "$previous" != --session ] || session="$current"
      [ "$previous" != --engine ] || engine="$current"
      previous="$current"
    done
    jq -cn --arg sid "$session" --arg engine "$engine" \
      '{action:"monitor-check",session_id:$sid,engine:$engine,active_lane_ids:[],uncovered_lane_ids:[],monitor_calls:[]}'
    ;;
  *)
    printf 'unexpected stub command\n' >&2
    exit 64
    ;;
esac
SH
chmod +x "$BIN/hq"

make_session() {
  local sid="$1" company="${2:-indigo}"
  mkdir -p "$FIX/workspace/sessions/$sid"
  if [ "$company" = none ]; then
    printf 'session_id: %s\n' "$sid" > "$FIX/workspace/sessions/$sid/meta.yaml"
  else
    printf 'session_id: %s\ncompany_slug: %s\n' "$sid" "$company" \
      > "$FIX/workspace/sessions/$sid/meta.yaml"
  fi
}

dispatch() {
  local sid="$1" lanes_mode="$2" company="${3:-indigo}" preflight_mode="${4:-fast}" \
    mesh_mode="${5:-slow}" repair_mode="${6:-fast}" cwd="${7:-$FIX}" start end payload
  make_session "$sid" "$company"
  mkdir -p "$FIX/workspace/lanes/lanes"
  printf '{"lane_id":"fixture-%s","state":"running","senior":{"kind":"session","id":"%s"}}\n' \
    "$sid" "$sid" > "$FIX/workspace/lanes/lanes/fixture-$sid.json"
  payload="$(jq -nc --arg sid "$sid" --arg cwd "$cwd" \
    '{hook_event_name:"SessionStart",source:"startup",session_id:$sid,cwd:$cwd,engine:"claude"}')"
  start="$(now_ms)"
  printf '%s' "$payload" | safe_env \
    TEST_MESH_PID_FILE="$MESH_PID_FILE" TEST_MESH_CHILD_PID_FILE="$MESH_CHILD_PID_FILE" \
    TEST_MESH_STARTED="$MESH_STARTED" TEST_MESH_DONE="$MESH_DONE" \
    TEST_MESH_INVOCATIONS="$MESH_INVOCATIONS" \
    TEST_MESH_OBSERVATIONS="$MESH_OBSERVATIONS" \
    TEST_MESH_RECORD_LOG="$MESH_RECORD_LOG" \
    TEST_MESH_RELEASE_FIRST="$MESH_RELEASE_FIRST" \
    TEST_LANES_PID_FILE="$LANES_PID_FILE" TEST_LANES_CHILD_PID_FILE="$LANES_CHILD_PID_FILE" \
    TEST_LANES_STARTED="$LANES_STARTED" TEST_LANES_DONE="$LANES_DONE" \
    TEST_REGISTER_PID_FILE="$REGISTER_PID_FILE" TEST_REGISTER_CHILD_PID_FILE="$REGISTER_CHILD_PID_FILE" \
    TEST_REGISTER_STARTED="$REGISTER_STARTED" TEST_REGISTER_DONE="$REGISTER_DONE" \
    TEST_REGISTER_PGID_FILE="$REGISTER_PGID_FILE" TEST_MESH_PGID_FILE="$MESH_PGID_FILE" \
    TEST_LANES_PGID_FILE="$LANES_PGID_FILE" TEST_PREFLIGHT_PID_FILE="$PREFLIGHT_PID_FILE" \
    TEST_PREFLIGHT_CHILD_PID_FILE="$PREFLIGHT_CHILD_PID_FILE" \
    TEST_PREFLIGHT_STARTED="$PREFLIGHT_STARTED" TEST_PREFLIGHT_DONE="$PREFLIGHT_DONE" \
    TEST_PREFLIGHT_PGID_FILE="$PREFLIGHT_PGID_FILE" \
    TEST_PREFLIGHT_NO_UPDATE_FILE="$PREFLIGHT_NO_UPDATE_FILE" \
    TEST_VALID_PREFLIGHT_READY="$VALID_PREFLIGHT_READY" \
    TEST_REPAIR_PID_FILE="$REPAIR_PID_FILE" TEST_REPAIR_CHILD_PID_FILE="$REPAIR_CHILD_PID_FILE" \
    TEST_REPAIR_STARTED="$REPAIR_STARTED" TEST_REPAIR_DONE="$REPAIR_DONE" \
    TEST_REPAIR_PGID_FILE="$REPAIR_PGID_FILE" TEST_REPAIR_NO_UPDATE_FILE="$REPAIR_NO_UPDATE_FILE" \
    TEST_PREFLIGHT_MODE="$preflight_mode" TEST_MESH_MODE="$mesh_mode" TEST_REPAIR_MODE="$repair_mode" \
    TEST_LANES_MODE="$lanes_mode" \
    HQ_WORK_MESH_RECONCILE_DIR="$TMP/reconcile-locks" \
    HQ_WORK_MESH_RECONCILE_WORKER_PID_FILE="$RECONCILE_WORKERS" \
    HQ_REGISTER_PENDING_DIR="$TMP/register-locks" HQ_HOOK_TIMEOUT_SENTRY=0 \
    timeout --foreground 6s bash "$FIX/.claude/hooks/master-hook.sh" SessionStart \
    > "$TMP/dispatch.out" 2> "$TMP/dispatch.err"
  DISPATCH_RC=$?
  end="$(now_ms)"
  DISPATCH_MS=$((end - start))
}

echo "[1] slow work-mesh reconcile is detached and deadline-bound"
dispatch c179b-slow-mesh fast
[ "$DISPATCH_RC" -eq 0 ] && pass "SessionStart dispatch returns normally" \
  || fail "SessionStart dispatch rc=$DISPATCH_RC: $(cat "$TMP/dispatch.err")"
[ "$DISPATCH_MS" -le 5500 ] && pass "slow reconcile does not hold SessionStart (elapsed=${DISPATCH_MS}ms)" \
  || fail "slow reconcile held SessionStart for ${DISPATCH_MS}ms"
for ((attempt=0; attempt<60; attempt++)); do
  [ -f "$MESH_STARTED" ] && break
  sleep 0.05
done
[ -f "$MESH_STARTED" ] && pass "detached reconcile started" || fail "detached reconcile did not start"
mesh_pid="$(cat "$MESH_PID_FILE" 2>/dev/null || true)"
if [[ "$mesh_pid" =~ ^[0-9]+$ ]] && kill -0 "$mesh_pid" 2>/dev/null; then
  pass "detached reconcile is still running after SessionStart returns"
else
  fail "detached reconcile did not remain active after SessionStart returned"
fi
for ((attempt=0; attempt<240; attempt++)); do
  [ -f "$MESH_DONE" ] && break
  sleep 0.05
done
[ "$(cat "$MESH_DONE" 2>/dev/null || true)" = stopped ] \
  && pass "detached reconcile exits at its own deadline" \
  || fail "detached reconcile did not stop at its own deadline"
for ((attempt=0; attempt<40; attempt++)); do
  [ ! -e "$TMP/reconcile-locks/c179b-slow-mesh.lock" ] && break
  sleep 0.05
done
[ ! -e "$TMP/reconcile-locks/c179b-slow-mesh.lock" ] \
  && pass "detached reconcile releases its single-flight lock" \
  || fail "detached reconcile left its single-flight lock"

echo "[1b] detached reconcile permits work that completes after five seconds"
rm -f "$MESH_DONE" "$MESH_STARTED" "$MESH_PID_FILE"
dispatch c179b-after-five fast indigo fast after-five
[ "$DISPATCH_RC" -eq 0 ] && pass "after-five reconcile does not hold SessionStart" \
  || fail "after-five reconcile held SessionStart rc=$DISPATCH_RC"
for ((attempt=0; attempt<160; attempt++)); do
  [ -f "$MESH_DONE" ] && break
  sleep 0.05
done
[ "$(cat "$MESH_DONE" 2>/dev/null || true)" = completed ] \
  && pass "detached reconcile completes after five seconds within its ten-second deadline" \
  || fail "detached reconcile did not complete after five seconds (state=$(cat "$MESH_DONE" 2>/dev/null || true))"
for ((attempt=0; attempt<40; attempt++)); do
  [ ! -e "$TMP/reconcile-locks/c179b-after-five.lock" ] && break
  sleep 0.05
done
[ ! -e "$TMP/reconcile-locks/c179b-after-five.lock" ] \
  && pass "after-five reconcile releases its single-flight lock" \
  || fail "after-five reconcile left its single-flight lock"
for ((attempt=0; attempt<60; attempt++)); do
  [ -f "$REGISTER_STARTED" ] && break
  sleep 0.05
done
[ -f "$REGISTER_STARTED" ] && pass "pending registration retry started detached" \
  || fail "pending registration retry did not start"
for ((attempt=0; attempt<140; attempt++)); do
  [ "$(cat "$REGISTER_DONE" 2>/dev/null || true)" = stopped ] && break
  sleep 0.05
done
[ "$(cat "$REGISTER_DONE" 2>/dev/null || true)" = stopped ] \
  && pass "pending registration retry exits at its own deadline" \
  || fail "pending registration retry did not stop at its own deadline"
for ((attempt=0; attempt<40; attempt++)); do
  [ ! -e "$TMP/register-locks/indigo.lock" ] && break
  sleep 0.05
done
[ ! -e "$TMP/register-locks/indigo.lock" ] \
  && pass "pending registration retry releases its single-flight lock" \
  || fail "pending registration retry left its single-flight lock"

echo "[2] slow lanes context lookup is bounded and cannot write after return"
dispatch c179b-slow-lanes slow
[ "$DISPATCH_MS" -le 5500 ] && pass "slow context lookup stays inside the SessionStart bound (elapsed=${DISPATCH_MS}ms)" \
  || fail "slow context lookup held SessionStart for ${DISPATCH_MS}ms"
[ "$DISPATCH_RC" -ne 124 ] && pass "bounded lookup returns before dispatcher timeout" \
  || fail "slow context lookup reached the dispatcher timeout"
[ -f "$LANES_STARTED" ] && pass "lanes command was started" || fail "lanes command was not started"
[ "$(cat "$LANES_DONE" 2>/dev/null || true)" = stopped ] \
  && pass "timed-out lanes command was reaped" || fail "timed-out lanes command was not reaped"
if [ -s "$TMP/dispatch.out" ] && grep -q late-context "$TMP/dispatch.out"; then
  fail "detached output appeared after SessionStart returned"
else
  pass "no late lanes output is emitted after SessionStart returns"
fi

echo "[3] slow unbound preflight is bounded and disables self-update"
dispatch c179b-slow-preflight fast none slow fast
[ "$DISPATCH_RC" -eq 0 ] && pass "unbound SessionStart dispatch returns normally" \
  || fail "unbound SessionStart dispatch rc=$DISPATCH_RC: $(cat "$TMP/dispatch.err")"
[ "$DISPATCH_MS" -le 5500 ] && pass "slow offline preflight stays inside the SessionStart bound (elapsed=${DISPATCH_MS}ms)" \
  || fail "offline preflight held SessionStart for ${DISPATCH_MS}ms"
[ -f "$PREFLIGHT_STARTED" ] && pass "slow offline preflight was exercised" \
  || fail "slow offline preflight did not start"
[ "$(cat "$PREFLIGHT_DONE" 2>/dev/null || true)" = stopped ] \
  && pass "timed-out offline preflight process group was reaped" \
  || fail "timed-out offline preflight process group was not reaped"
[ "$(cat "$PREFLIGHT_NO_UPDATE_FILE" 2>/dev/null || true)" = 1 ] \
  && pass "offline preflight disables hq self-update" \
  || fail "offline preflight did not disable hq self-update"

echo "[4] slow held-default read after valid preflight is bounded"
dispatch c179b-slow-repair fast none valid fast slow
[ "$DISPATCH_RC" -eq 0 ] && pass "validated unbound SessionStart returns normally" \
  || fail "validated unbound SessionStart rc=$DISPATCH_RC: $(cat "$TMP/dispatch.err")"
[ "$DISPATCH_MS" -le 5500 ] && pass "slow held-default read stays inside the SessionStart bound (elapsed=${DISPATCH_MS}ms)" \
  || fail "held-default read held SessionStart for ${DISPATCH_MS}ms"
[ -f "$REPAIR_STARTED" ] && pass "held-default read after valid offline preflight was exercised" \
  || fail "held-default read after valid offline preflight did not start"
[ "$(cat "$REPAIR_DONE" 2>/dev/null || true)" = stopped ] \
  && pass "timed-out held-default process group was reaped" \
  || fail "timed-out held-default process group was not reaped"
if awk 'NF != 1 || $0 != "1" { bad=1 } END { exit bad || NR == 0 }' "$REPAIR_NO_UPDATE_FILE" 2>/dev/null; then
  pass "every held-default hq invocation disables self-update"
else
  fail "held-default hq invocation did not set HQ_NO_UPDATE_CHECK=1: $(cat "$REPAIR_NO_UPDATE_FILE" 2>/dev/null || true)"
fi
echo "[4a] direct device-default resolver disables hq self-update"
: > "$REPAIR_NO_UPDATE_FILE"
rm -f "$REPAIR_STARTED" "$REPAIR_DONE" "$REPAIR_PID_FILE" "$REPAIR_CHILD_PID_FILE" "$REPAIR_PGID_FILE"
safe_env TEST_VALID_PREFLIGHT_READY="$VALID_PREFLIGHT_READY" TEST_REPAIR_MODE=slow \
  TEST_REPAIR_NO_UPDATE_FILE="$REPAIR_NO_UPDATE_FILE" TEST_REPAIR_PID_FILE="$REPAIR_PID_FILE" \
  TEST_REPAIR_CHILD_PID_FILE="$REPAIR_CHILD_PID_FILE" TEST_REPAIR_STARTED="$REPAIR_STARTED" \
  TEST_REPAIR_DONE="$REPAIR_DONE" TEST_REPAIR_PGID_FILE="$REPAIR_PGID_FILE" \
  bash -c '. "$1"; session_auto_bind_device_default "$2" >/dev/null' _ \
    "$FIX/core/scripts/lib/session-auto-bind.sh" "$FIX"
[ -f "$REPAIR_STARTED" ] && pass "device-default hq invocation was exercised" \
  || fail "device-default hq invocation did not start"
[ "$(cat "$REPAIR_DONE" 2>/dev/null || true)" = stopped ] \
  && pass "device-default timeout reaps the hq process" \
  || fail "device-default timeout did not reap hq"
if awk 'NF != 1 || $0 != "1" { bad=1 } END { exit bad || NR != 1 }' "$REPAIR_NO_UPDATE_FILE" 2>/dev/null; then
  pass "session_auto_bind_device_default disables hq self-update"
else
  fail "session_auto_bind_device_default HQ_NO_UPDATE_CHECK='$(cat "$REPAIR_NO_UPDATE_FILE" 2>/dev/null || true)'"
fi
if grep -q '^company_slug:' "$FIX/workspace/sessions/c179b-slow-repair/meta.yaml"; then
  fail "timed-out held-default read changed the existing unbound session context"
else
  pass "timed-out held-default read preserves the existing unbound session context"
fi

echo "[5] stale reaper mutexes do not permanently block a reconcile"
stale_lock="$TMP/reconcile-locks/c179b-stale-reaper.lock"
mkdir -p "$stale_lock" "$stale_lock.reclaim"
printf '%s\n' 99999999 > "$stale_lock/pid"
touch -t 200001010000 "$stale_lock" "$stale_lock.reclaim"
dispatch c179b-stale-reaper fast indigo fast record
for ((attempt=0; attempt<120; attempt++)); do
  [ -s "$MESH_RECORD_LOG" ] && break
  sleep 0.05
done
grep -qx "$FIX" "$MESH_RECORD_LOG" 2>/dev/null \
  && pass "stale reclaim mutex was recovered and reconcile ran" \
  || fail "stale reclaim mutex prevented reconcile from running"
[ ! -e "$stale_lock.reclaim" ] \
  && pass "abandoned reclaim directory is removed" \
  || fail "abandoned reclaim directory remains wedged"

echo "[6] queued reconciles consume the newest pending observation after the holder exits"
mkdir -p "$FIX/older-observation" "$FIX/latest-observation"
: > "$MESH_OBSERVATIONS"
rm -f "$MESH_RELEASE_FIRST" "$MESH_STARTED"
dispatch c179b-latest-pending fast indigo fast sequence fast "$FIX"
for ((attempt=0; attempt<100; attempt++)); do
  [ -f "$MESH_STARTED" ] && break
  sleep 0.05
done
[ -f "$MESH_STARTED" ] && pass "first reconcile owns the session lock" \
  || fail "first reconcile did not acquire the session lock"
dispatch c179b-latest-pending fast indigo fast sequence fast "$FIX/older-observation"
older_dispatch_ms=$DISPATCH_MS
dispatch c179b-latest-pending fast indigo fast sequence fast "$FIX/latest-observation"
latest_dispatch_ms=$DISPATCH_MS
[ "$older_dispatch_ms" -le 5500 ] && [ "$latest_dispatch_ms" -le 5500 ] \
  && pass "queued SessionStart calls return within the dispatch bound" \
  || fail "a queued SessionStart call exceeded its dispatch bound"
touch "$MESH_RELEASE_FIRST"
for ((attempt=0; attempt<200; attempt++)); do
  [ "$(wc -l < "$MESH_OBSERVATIONS" 2>/dev/null || printf '0')" -ge 2 ] && break
  sleep 0.05
done
if [ "$(wc -l < "$MESH_OBSERVATIONS" 2>/dev/null || printf '0')" -eq 2 ] \
  && [ "$(sed -n '1p' "$MESH_OBSERVATIONS")" = "$FIX|before-release" ] \
  && [ "$(sed -n '2p' "$MESH_OBSERVATIONS")" = "$FIX/latest-observation|after-release" ]; then
  pass "the newest pending observation is reconciled after the lock holder exits"
else
  fail "pending observations were dropped or an older observation won: $(cat "$MESH_OBSERVATIONS" 2>/dev/null || true)"
fi

echo "[7] external termination reaches the detached command group"
cat > "$BIN/node" <<'NODE'
#!/usr/bin/env bash
if [ -n "${TEST_NODE_PID_FILE:-}" ]; then
  printf '%s\n' "$$" > "$TEST_NODE_PID_FILE"
fi
exec "$TEST_REAL_NODE" "$@"
NODE
chmod +x "$BIN/node"
cat > "$TMP/signal-child.sh" <<'CHILD'
#!/usr/bin/env bash
trap 'printf "%s\n" stopped > "$TEST_SIGNAL_STOPPED"; exit 0' TERM INT
ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]' > "$TEST_SIGNAL_CHILD_PGID_FILE"
printf '%s\n' started > "$TEST_SIGNAL_STARTED"
sleep 30 &
printf '%s\n' "$!" > "$TEST_SIGNAL_CHILD_PID_FILE"
wait "$!"
CHILD
chmod +x "$TMP/signal-child.sh"
safe_env TEST_REAL_NODE="$NODE_BIN" TEST_NODE_PID_FILE="$SIGNAL_NODE_PID_FILE" \
  TEST_SIGNAL_STARTED="$SIGNAL_CHILD_STARTED" TEST_SIGNAL_STOPPED="$SIGNAL_CHILD_STOPPED" \
  TEST_SIGNAL_CHILD_PID_FILE="$SIGNAL_CHILD_PID_FILE" \
  TEST_SIGNAL_CHILD_PGID_FILE="$SIGNAL_CHILD_PGID_FILE" \
  /bin/bash -c '. "$1"; session_auto_bind_run_with_timeout --timeout-ms 5000 "$2"' \
  _ "$FIX/core/scripts/lib/session-auto-bind.sh" "$TMP/signal-child.sh" \
  > "$TMP/signal-wrapper.out" 2> "$TMP/signal-wrapper.err" &
signal_runner=$!
for ((attempt=0; attempt<100; attempt++)); do
  [ -f "$SIGNAL_NODE_PID_FILE" ] && [ -f "$SIGNAL_CHILD_STARTED" ] && break
  sleep 0.02
done
signal_node_pid="$(cat "$SIGNAL_NODE_PID_FILE" 2>/dev/null || true)"
if [[ "$signal_node_pid" =~ ^[0-9]+$ ]]; then
  kill -TERM "$signal_node_pid" 2>/dev/null || true
else
  fail "timeout wrapper Node process was not recorded"
fi
for ((attempt=0; attempt<100; attempt++)); do
  [ -f "$SIGNAL_CHILD_STOPPED" ] && break
  sleep 0.02
done
signal_rc=0
wait "$signal_runner" || signal_rc=$?
[ "$signal_rc" -eq 143 ] && pass "external TERM returns the conventional wrapper status" \
  || fail "external TERM returned status $signal_rc"
[ -f "$SIGNAL_CHILD_STOPPED" ] && pass "external TERM is forwarded to the detached process group" \
  || fail "detached child did not receive external TERM"

echo "[8] successful child output is drained before the wrapper exits"
cat > "$TMP/large-output-child.sh" <<'CHILD'
#!/usr/bin/env bash
head -c 1048576 /dev/zero
head -c 1048576 /dev/zero >&2
CHILD
chmod +x "$TMP/large-output-child.sh"
large_rc=0
safe_env TEST_REAL_NODE="$NODE_BIN" \
  /bin/bash -c '. "$1"; session_auto_bind_run_with_timeout --timeout-ms 5000 --capture-stderr "$2"' \
  _ "$FIX/core/scripts/lib/session-auto-bind.sh" "$TMP/large-output-child.sh" \
  > "$LARGE_STDOUT" 2> "$LARGE_STDERR" || large_rc=$?
[ "$large_rc" -eq 0 ] && pass "large-output child exits successfully" \
  || fail "large-output child returned status $large_rc"
[ "$(wc -c < "$LARGE_STDOUT")" -eq 1048576 ] \
  && pass "all stdout bytes are forwarded before close" \
  || fail "stdout was truncated ($(wc -c < "$LARGE_STDOUT") bytes)"
[ "$(wc -c < "$LARGE_STDERR")" -eq 1048576 ] \
  && pass "all captured stderr bytes are forwarded before close" \
  || fail "stderr was truncated ($(wc -c < "$LARGE_STDERR") bytes)"

if [ "$FAIL" -gt 0 ]; then
  printf 'FAIL: %s assertion(s) failed\n' "$FAIL" >&2
  exit 1
fi
printf 'PASS: SessionStart slow work is bounded and detached\n'
