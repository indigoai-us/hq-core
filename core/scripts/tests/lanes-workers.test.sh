#!/usr/bin/env bash
# Focused coverage for lane-native role setup and the preserved QA/CI helpers.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/core/scripts/lib" "$T/core/scripts" "$T/workspace/sessions/test-session" "$T/.claude/skills/conduct/roles" "$T/bin"
cp "$ROOT/core/scripts/lanes-workers.sh" "$T/core/scripts/"
cp "$ROOT/core/scripts/hq-session.sh" "$T/core/scripts/"
cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$T/core/scripts/lib/"
cp "$ROOT/core/scripts/lib/session-id.sh" "$T/core/scripts/lib/"
cp "$ROOT/.claude/skills/conduct/roles/"*.md "$T/.claude/skills/conduct/roles/"
WATCHER_SOURCE="${HQ_TEST_WATCHER_SRC:-$ROOT/core/scripts/lanes-completion-watch.sh}"
cp "$WATCHER_SOURCE" "$T/core/scripts/lanes-completion-watch.sh"
chmod +x "$T/core/scripts/lanes-completion-watch.sh"
printf 'session_id: test-session\n' > "$T/workspace/sessions/test-session/meta.yaml"
export HQ_ROOT="$T" HQ_SESSION_ID=test-session
unset CLAUDE_PROJECT_DIR
W() { bash "$T/core/scripts/lanes-workers.sh" "$@"; }
S() { bash "$T/core/scripts/hq-session.sh" --session-id test-session "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

if [ -z "${HQ_TEST_ONLY_CASE:-}" ]; then
out="$(W setup --session-id test-session --workers 'frontend, designer,qa,frontend' --engine codex --model gpt-test --effort high)"
eq "$(S get conduct_lane_roles)" 'frontend,designer,qa' 'deduped role list'
eq "$(S get conduct_engine)" codex 'provider pin'
eq "$(S get conduct_child_model)" gpt-test 'model pin'
eq "$(S get conduct_child_effort)" high 'effort pin'
case "$out" in *'"roles":["frontend","designer","qa"]'*) : ;; *) fail "setup JSON omitted roles" ;; esac
W setup --session-id test-session --workers 'Front End' >/dev/null 2>&1 && fail 'invalid role accepted'

# Port of 942d38f2: switching an automatic Codex engine clears only automatic
# model/effort pins that were not explicitly replaced.
S set conduct_engine codex
S set conduct_child_model automatic-codex-model
S set conduct_child_effort high
S set conduct_default_source codex-session
W setup --session-id test-session --workers frontend --engine claude >/dev/null
eq "$(S get conduct_engine)" claude 'explicit engine replaces Codex'
eq "$(S get conduct_child_model)" '' 'automatic Codex model is cleared'
eq "$(S get conduct_child_effort)" '' 'automatic Codex effort is cleared'
eq "$(S get conduct_default_source)" explicit 'Codex override provenance'
S set conduct_engine codex
S set conduct_child_model automatic-codex-model
S set conduct_child_effort high
S set conduct_default_source codex-session
W setup --session-id test-session --workers frontend --engine claude --model chosen-model >/dev/null
eq "$(S get conduct_child_model)" chosen-model 'explicit model replaces automatic pin'
eq "$(S get conduct_child_effort)" '' 'unspecified automatic effort is cleared'
W setup --session-id test-session --workers frontend --engine codex --model chosen-codex-model >/dev/null
eq "$(S get conduct_child_model)" chosen-codex-model 'selected Codex model remains pinned'
eq "$(S get conduct_default_source)" explicit 'selected Codex model is explicit'
eq "$(W roles --session-id test-session | jq -r .engine)" codex 'roles reports pins'
eq "$(W template --role qa)" '.claude/skills/conduct/roles/qa.md' 'qa template'
eq "$(W template --role data)" '.claude/skills/conduct/roles/generic.md' 'generic fallback'
for role in frontend designer backend qa orchestrator generic; do
  [ -f "$ROOT/.claude/skills/conduct/roles/$role.md" ] || fail "missing $role template"
  grep -q '^Execute this now' "$ROOT/.claude/skills/conduct/roles/$role.md" || fail "$role template opener"
done

W needs-qa --role frontend >/dev/null || fail 'frontend needs QA'
W needs-qa --role backend --file src/App.svelte >/dev/null || fail 'svelte needs QA'
W needs-qa --role backend --file view/X.tsx >/dev/null || fail 'tsx needs QA'
W needs-qa --role backend --file view/X.jsx >/dev/null || fail 'jsx needs QA'
W needs-qa --role backend --file view/X.vue >/dev/null || fail 'vue needs QA'
W needs-qa --role backend --file view/X.css >/dev/null || fail 'css needs QA'
W needs-qa --role backend --file view/X.scss >/dev/null || fail 'scss needs QA'
W needs-qa --role backend --file view/X.sass >/dev/null || fail 'sass needs QA'
W needs-qa --role backend --file view/X.less >/dev/null || fail 'less needs QA'
W needs-qa --role backend --file src/server.ts >/dev/null 2>&1 && fail 'server-only change should not need QA'

cat > "$T/bin/gh" <<'SH'
#!/bin/sh
case "$*" in
  *'pr checks'*) printf '%s' '[{"name":"lint","bucket":"pass"},{"name":"tests","bucket":"pass"}]' ;;
  *'pr view'*) printf '%s\n' 'src/App.tsx' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/gh"
PATH="$T/bin:$PATH" W needs-qa --role backend --pr 12 >/dev/null || fail 'PR UI file should need QA'
printf '#!/bin/sh\nexit 1\n' > "$T/bin/gh"
chmod +x "$T/bin/gh"
set +e
PATH="$T/bin:$PATH" W needs-qa --role backend --pr 12 >/dev/null 2>&1; code=$?
set -e
[ "$code" -eq 2 ] || fail 'gh failure in needs-qa must be an error'

mkgh() { printf '#!/bin/sh\nprintf %%s %s\nexit %s\n' "'$1'" "$2" > "$T/bin/gh"; chmod +x "$T/bin/gh"; }
mkgh '[{"name":"lint","bucket":"pass"},{"name":"tests","bucket":"pass"},{"name":"e2e","bucket":"skipping"}]' 0
set +e
out="$(PATH="$T/bin:$PATH" W ci --pr 12 --timeout 2 --interval 1 --settle 0)"; code=$?
set -e
eq "$code" 0 'settled passing CI'
case "$out" in *'"state":"pass"'*) : ;; *) fail "passing CI result malformed: $out" ;; esac
set +e
PATH="$T/bin:$PATH" W ci --pr 12 --timeout 0 --interval 1 >/dev/null; code=$?
set -e
eq "$code" 2 'a pass inside the settle window is not final'
mkgh '[{"name":"lint","bucket":"pass"},{"name":"tests","bucket":"fail"},{"name":"build","bucket":"pending"}]' 1
set +e
out="$(PATH="$T/bin:$PATH" W ci --pr 12 --timeout 0 --interval 1)"; code=$?
set -e
eq "$code" 1 'failure wins over pending'
case "$out" in *'"failing":["tests"]'*) : ;; *) fail 'failing CI check was not named' ;; esac
mkgh '[{"name":"build","bucket":"pending"}]' 8
set +e
out="$(PATH="$T/bin:$PATH" W ci --pr 12 --timeout 2 --interval 1)"; code=$?
set -e
eq "$code" 2 'pending checks time out'
mkgh 'HTTP 401: bad credentials' 1
set +e
out="$(PATH="$T/bin:$PATH" W ci --pr 12 --timeout 0 --interval 1)"; code=$?
set -e
eq "$code" 3 'gh error fails closed'
case "$out" in *'"state":"error"'*) : ;; *) fail 'gh error was not reported as error' ;; esac
mkgh '[]' 0
set +e
PATH="$T/bin:$PATH" W ci --pr 12 --timeout 2 --interval 1 --settle 0 >/dev/null; code=$?
set -e
eq "$code" 4 'no checks is distinct from pass'

cat > "$T/bin/gh" <<SH
#!/bin/sh
n=\$(cat "$T/gh-calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$T/gh-calls"
case "\$n" in
  1) printf '%s' '[{"name":"early","bucket":"pass"}]' ;;
  2) printf '%s' '[{"name":"early","bucket":"pass"},{"name":"pr-checks","bucket":"pending"}]'; exit 8 ;;
  *) printf '%s' '[{"name":"early","bucket":"pass"},{"name":"pr-checks","bucket":"fail"}]'; exit 1 ;;
esac
SH
chmod +x "$T/bin/gh"
set +e
out="$(PATH="$T/bin:$PATH" W ci --pr 12 --timeout 10 --interval 1 --settle 0)"; code=$?
set -e
eq "$code" 1 'late-registered failing check is caught'
case "$out" in *'"failing":["pr-checks"]'*) : ;; *) fail 'late check failure was missed' ;; esac
eq "$(W ci-round --session-id test-session --pr 12)" 1 'first CI round'
eq "$(W ci-round --session-id test-session --pr 12)" 2 'second CI round'
eq "$(W ci-round --session-id test-session --pr 13)" 1 'rounds are per PR'

if rg -n 'conduct-pool\.sh|conduct-inbox\.sh|workflow-runner' "$T/core/scripts/lanes-workers.sh"; then
  fail 'lane worker helper retained a conduct-pool, inbox, or workflow-runner dependency'
fi
fi

echo 'lanes-completion-watch: Codex delivery is durable, scoped, and exactly once'
mkdir -p "$T/bin" "$T/fake-hq"
export HQ_SHOW_SEQUENCE="$T/fake-hq/show-sequence"
export HQ_SHOW_COUNT="$T/fake-hq/show-count"
export HQ_WAIT_SEQUENCE="$T/fake-hq/wait-sequence"
export HQ_WAIT_COUNT="$T/fake-hq/wait-count"
export HQ_MONITOR_TARGETS="$T/fake-hq/monitor-targets"
export HQ_MONITOR_COMMANDS="$T/fake-hq/monitor-commands"
export HQ_MONITOR_COUNT="$T/fake-hq/monitor-count"
N="$T/core/scripts/lanes-completion-watch.sh"

cat > "$T/bin/hq" <<'SH'
#!/bin/sh
set -eu
if [ "$1 $2" = "monitor start" ]; then
  shift 2
  n=$(cat "$HQ_MONITOR_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "$HQ_MONITOR_COUNT"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target) printf '%s\n' "$2" >> "$HQ_MONITOR_TARGETS"; shift 2 ;;
      --command) printf '%s\n' "$2" >> "$HQ_MONITOR_COMMANDS"; shift 2 ;;
      --description) shift 2 ;;
      --persistent|--json) shift ;;
      *) exit 2 ;;
    esac
  done
  [ "${HQ_MONITOR_FAIL:-0}" = 0 ] || { printf '%s\n' '{"ok":false}'; exit 0; }
  printf '{"ok":true,"monitor_id":"mon-test-%s"}\n' "$n"
elif [ "$1" = lanes ] && [ "$2" = wait ]; then
  n=$(cat "$HQ_WAIT_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "$HQ_WAIT_COUNT"
  mode=$(sed -n "${n}p" "$HQ_WAIT_SEQUENCE" 2>/dev/null || true)
  [ -n "$mode" ] || mode=$(tail -n 1 "$HQ_WAIT_SEQUENCE" 2>/dev/null || true)
  case "$mode" in
    ok) printf '%s\n' '{"ok":true,"change":{"type":"envelope"}}' ;;
    ok-timeout) if [ "$n" -eq 1 ]; then printf '%s\n' '{"ok":true,"change":{"type":"envelope"}}'; else sleep 1; printf '%s\n' '{"ok":false,"error":"wait_timeout"}'; fi ;;
    timeout) sleep 1; printf '%s\n' '{"ok":false,"error":"wait_timeout"}' ;;
    bad) printf '%s\n' '{"ok":false,"error":"unexpected"}' ;;
    *) exit 2 ;;
  esac
elif [ "$1" = lanes ] && [ "$2" = show ]; then
  n=$(cat "$HQ_SHOW_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "$HQ_SHOW_COUNT"
  answer=$(sed -n "${n}p" "$HQ_SHOW_SEQUENCE" 2>/dev/null || true)
  [ -n "$answer" ] || answer=$(tail -n 1 "$HQ_SHOW_SEQUENCE" 2>/dev/null || true)
  [ -n "$answer" ] || exit 2
  printf '%s\n' "$answer"
else
  exit 2
fi
SH
chmod +x "$T/bin/hq"

S1='2026-10-10T00:52:20Z'
S2='2026-10-10T00:52:21Z'
S3='2026-10-10T00:52:22Z'
R1='round-one'
R2='round-two'
R3='round-three'
POLL_SECONDS=3

round_key() { printf '%s' "$1" | tr -d ':-'; }
test_round_key() { printf '%s-%s' "$(round_key "$1")" "$2"; }
round_dir() { printf '%s/workspace/lanes-runs/%s/codex-completion' "$T" "$1"; }
receipt_for() {
  if [ "${HQ_TEST_BASELINE:-0}" = 1 ]; then
    printf '%s/workspace/lanes-runs/%s/codex-completion.json' "$T" "$1"
  else
    printf '%s/%s.json' "$(round_dir "$1")" "$(test_round_key "$2" "$3")"
  fi
}
monitor_record_for() { printf '%s/%s.monitor.json' "$(round_dir "$1")" "$(test_round_key "$2" "$3")"; }
monitor_lock_for() { printf '%s/%s.monitor.lock' "$(round_dir "$1")" "$(test_round_key "$2" "$3")"; }
receipt_lock_for() { printf '%s/%s.lock' "$(round_dir "$1")" "$(test_round_key "$2" "$3")"; }
prepare_lane() {
  local lane="$1" show="$2" wait_mode="$3"
  mkdir -p "$T/workspace/lanes-runs/$lane/logs"
  printf '%s\n' "$show" > "$HQ_SHOW_SEQUENCE"
  : > "$HQ_SHOW_COUNT"
  printf '%s\n' "$wait_mode" > "$HQ_WAIT_SEQUENCE"
  : > "$HQ_WAIT_COUNT"
}
start_monitor() {
  local lane="$1" since="$2" round_id="$3"
  if [ "${HQ_TEST_BASELINE:-0}" = 1 ]; then
    HQ_ROOT="$T" PATH="$T/bin:$PATH" CODEX_SESSION_ID=codex-parent \
      "$N" start --lane "$lane" --provider codex --session-id codex-parent
  else
    HQ_ROOT="$T" PATH="$T/bin:$PATH" CODEX_SESSION_ID=codex-parent \
      "$N" start --lane "$lane" --provider codex --session-id codex-parent --since "$since" --round-id "$round_id"
  fi
}
launch_emit() {
  local lane="$1" since="$2" round_id="$3" output="$4" keep_receipt="${5:-}" receipt
  receipt="$(receipt_for "$lane" "$since" "$round_id")"
  [ "$keep_receipt" = keep ] || rm -f "$receipt"
  rm -f "$output" "$output.err"
  if [ "${HQ_TEST_BASELINE:-0}" = 1 ]; then
    HQ_ROOT="$T" PATH="$T/bin:$PATH" "$N" emit "$lane" 1 > "$output" 2>"$output.err" &
  else
    HQ_ROOT="$T" PATH="$T/bin:$PATH" "$N" emit "$lane" "$since" "$round_id" 1 > "$output" 2>"$output.err" &
  fi
  EMIT_PID=$!
}
poll_receipt() {
  local receipt="$1" waited=0
  while [ "$waited" -lt "$POLL_SECONDS" ]; do
    [ -f "$receipt" ] && return 0
    if ! kill -0 "$EMIT_PID" 2>/dev/null; then return 1; fi
    sleep 1
    waited=$((waited + 1))
  done
  [ -f "$receipt" ]
}
finish_emit() {
  local receipt="$1" output="$2" label="$3" count
  if ! poll_receipt "$receipt"; then
    kill "$EMIT_PID" 2>/dev/null || true
    wait "$EMIT_PID" 2>/dev/null || true
    fail "$label: expected a receipt within $POLL_SECONDS seconds"
  fi
  wait "$EMIT_PID" || fail "$label: emit did not exit successfully after writing the receipt"
  count=$(grep -c '^CONDUCT_LANE_COMPLETE ' "$output" 2>/dev/null || true)
  eq "$count" 1 "$label event count"
}
assert_event() {
  local output="$1" lane="$2" since="$3" state="$4" outcome="$5" ref="$6"
  jq -e --arg lane "$lane" --arg since "$since" --arg state "$state" \
    --arg outcome "$outcome" --arg ref "$ref" \
    '.kind == "conduct-lane-complete" and .lane_id == $lane and .since == $since and
     .lane_state == $state and .outcome == $outcome and .envelope_path == $ref and
     (.log_path | endswith("/logs/worker.out"))' "$output" >/dev/null \
    || fail 'completion receipt missing round, outcome, state, or paths'
}
done_lane() {
  local lane="$1" ref="$2" at="$3"
  printf '{"ok":true,"lane":{"lane_id":"%s","state":"done","updated_at":"%s","ended_at":null,"last_envelope":{"ref":"%s","at":"%s","decision":"done"}}}\n' \
    "$lane" "$at" "$ref" "$at"
}
state_lane() {
  local lane="$1" state="$2" ended="$3"
  printf '{"ok":true,"lane":{"lane_id":"%s","state":"%s","updated_at":"%s","ended_at":"%s","last_envelope":null}}\n' \
    "$lane" "$state" "$ended" "$ended"
}

test_t1() {
  local lane=lane-probe receipt out
  prepare_lane "$lane" "$(done_lane "$lane" envelopes/001.json 2026-10-10T00:52:22Z)" timeout
  receipt="$(receipt_for "$lane" "$S1" "$R1")"; out="$T/t1.event"
  launch_emit "$lane" "$S1" "$R1" "$out"
  finish_emit "$receipt" "$out" T1
  assert_event "$receipt" "$lane" "$S1" done done envelopes/001.json
}
test_t2() {
  local lane=lane-probe receipt out running done
  running='{"ok":true,"lane":{"lane_id":"lane-probe","state":"running","updated_at":"2026-10-10T00:52:20Z","ended_at":null,"last_envelope":null}}'
  done="$(done_lane "$lane" envelopes/002.json 2026-10-10T00:52:22Z)"
  prepare_lane "$lane" "$running" ok-timeout
  printf '%s\n%s\n' "$running" "$done" > "$HQ_SHOW_SEQUENCE"
  receipt="$(receipt_for "$lane" "$S1" "$R1")"; out="$T/t2.event"
  launch_emit "$lane" "$S1" "$R1" "$out"
  finish_emit "$receipt" "$out" T2
  assert_event "$receipt" "$lane" "$S1" done done envelopes/002.json
}
# T2b: the lane finishes while a wait is open but the wait times out without
# reporting it. The watcher must read the lane again after every timeout.
test_t2b() {
  local lane=lane-probe receipt out running done
  running='{"ok":true,"lane":{"lane_id":"lane-probe","state":"running","updated_at":"2026-10-10T00:52:20Z","ended_at":null,"last_envelope":null}}'
  done="$(done_lane "$lane" envelopes/002.json 2026-10-10T00:52:22Z)"
  prepare_lane "$lane" "$running" timeout
  printf '%s\n%s\n' "$running" "$done" > "$HQ_SHOW_SEQUENCE"
  receipt="$(receipt_for "$lane" "$S1" "$R1")"; out="$T/t2b.event"
  launch_emit "$lane" "$S1" "$R1" "$out"
  finish_emit "$receipt" "$out" T2b
  assert_event "$receipt" "$lane" "$S1" done done envelopes/002.json
}
test_t3_one() {
  local lane="$1" state="$2" receipt out
  prepare_lane "$lane" "$(state_lane "$lane" "$state" 2026-10-10T00:52:22Z)" ok-timeout
  receipt="$(receipt_for "$lane" "$S1" "$R1")"; out="$T/$lane.event"
  launch_emit "$lane" "$S1" "$R1" "$out"
  finish_emit "$receipt" "$out" "T3 $state"
  assert_event "$receipt" "$lane" "$S1" "$state" "$state" ''
}
test_t3() { test_t3_one lane-killed killed; test_t3_one lane-interrupted interrupted; }
test_t4() {
  local lane=lane-probe old done receipt out elapsed=0
  old="$(done_lane "$lane" envelopes/001.json 2026-10-10T00:52:19Z)"
  done="$(done_lane "$lane" envelopes/002.json 2026-10-10T00:52:22Z)"
  prepare_lane "$lane" "$old" timeout
  receipt="$(receipt_for "$lane" "$S1" "$R1")"; out="$T/t4.event"
  launch_emit "$lane" "$S1" "$R1" "$out"
  while [ "$elapsed" -lt 2 ]; do sleep 1; elapsed=$((elapsed + 1)); done
  [ ! -f "$receipt" ] || fail 'T4 reported the stale previous-round outcome'
  printf '%s\n' "$done" > "$HQ_SHOW_SEQUENCE"
  finish_emit "$receipt" "$out" T4
  assert_event "$receipt" "$lane" "$S1" done done envelopes/002.json
}
test_t5() {
  local lane=lane-reuse receipt1 receipt2 out1 out2 monitor2 before after cmd
  : > "$HQ_MONITOR_COUNT"; : > "$HQ_MONITOR_TARGETS"; : > "$HQ_MONITOR_COMMANDS"
  printf '0\n' > "$HQ_MONITOR_COUNT"
  prepare_lane "$lane" "$(done_lane "$lane" envelopes/001.json 2026-10-10T00:52:20Z)" ok
  start_monitor "$lane" "$S1" "$R1" >/dev/null || fail 'T5 round one monitor start'
  receipt1="$(receipt_for "$lane" "$S1" "$R1")"; out1="$T/t5-round1.event"
  launch_emit "$lane" "$S1" "$R1" "$out1"; finish_emit "$receipt1" "$out1" 'T5 round one'
  before=$(cat "$receipt1")
  printf '%s\n' "$(done_lane "$lane" envelopes/002.json 2026-10-10T00:52:22Z)" > "$HQ_SHOW_SEQUENCE"
  : > "$HQ_SHOW_COUNT"; printf 'timeout\n' > "$HQ_WAIT_SEQUENCE"; : > "$HQ_WAIT_COUNT"
  monitor2=$(start_monitor "$lane" "$S2" "$R2") || fail 'T5 round two monitor start'
  [ "$(cat "$HQ_MONITOR_COUNT")" -eq 2 ] || fail 'T5 second round did not schedule a second monitor'
  cmd=$(tail -n 1 "$HQ_MONITOR_COMMANDS")
  case "$cmd" in *"$S2"*"$R2"*) : ;; *) fail 'T5 second monitor command omitted round two identity' ;; esac
  [ "$(printf '%s' "$monitor2" | jq -r '.monitor_id')" = 'mon-test-2' ] || fail 'T5 second monitor id missing'
  after=$(cat "$receipt1"); eq "$after" "$before" 'T5 first round receipt remains unchanged'
  # Re-arming the exact same round prints its stored record without another monitor.
  eq "$(start_monitor "$lane" "$S2" "$R2")" "$monitor2" 'T6 same-round monitor record'
  [ "$(cat "$HQ_MONITOR_COUNT")" -eq 2 ] || fail 'T6 duplicate same-round start created another monitor'
  receipt2="$(receipt_for "$lane" "$S2" "$R2")"; out2="$T/t5-round2.event"
  launch_emit "$lane" "$S2" "$R2" "$out2"; finish_emit "$receipt2" "$out2" 'T5 round two'
  assert_event "$receipt2" "$lane" "$S2" done done envelopes/002.json
  eq "$(cat "$receipt1")" "$before" 'T5 round one receipt still unchanged'
}
test_t9() {
  local lane=lane-same-second receipt1 receipt2 out1 out2 monitor1 monitor2
  : > "$HQ_MONITOR_COUNT"; : > "$HQ_MONITOR_TARGETS"; : > "$HQ_MONITOR_COMMANDS"
  printf '0\n' > "$HQ_MONITOR_COUNT"
  prepare_lane "$lane" "$(done_lane "$lane" envelopes/001.json 2026-10-10T00:52:22Z)" ok
  monitor1=$(start_monitor "$lane" "$S1" "$R1") || fail 'T9 first same-second monitor start'
  monitor2=$(start_monitor "$lane" "$S1" "$R2") || fail 'T9 second same-second monitor start'
  [ "$(cat "$HQ_MONITOR_COUNT")" -eq 2 ] || fail 'T9 same-second round ID did not schedule a second monitor'
  [ "$(printf '%s' "$monitor1" | jq -r '.monitor_id')" != "$(printf '%s' "$monitor2" | jq -r '.monitor_id')" ] || fail 'T9 same-second rounds reused one monitor'
  receipt1="$(receipt_for "$lane" "$S1" "$R1")"; out1="$T/t9-round1.event"
  launch_emit "$lane" "$S1" "$R1" "$out1"; finish_emit "$receipt1" "$out1" 'T9 first same-second round'
  receipt2="$(receipt_for "$lane" "$S1" "$R2")"; out2="$T/t9-round2.event"
  launch_emit "$lane" "$S1" "$R2" "$out2"; finish_emit "$receipt2" "$out2" 'T9 second same-second round'
  [ -f "$receipt1" ] && [ -f "$receipt2" ] || fail 'T9 same-second rounds shared one receipt'
  eq "$(start_monitor "$lane" "$S1" "$R2")" "$monitor2" 'T9 duplicate second-round start'
  [ "$(cat "$HQ_MONITOR_COUNT")" -eq 2 ] || fail 'T9 duplicate start scheduled a third monitor'
}
test_t7() {
  local lane=lane-probe out bad before
  prepare_lane "$lane" "$(done_lane "$lane" envelopes/001.json 2026-10-10T00:52:22Z)" timeout
  before=$(cat "$HQ_MONITOR_COUNT" 2>/dev/null || echo 0)
  if [ "${HQ_TEST_BASELINE:-0}" = 1 ]; then
    out=$(HQ_ROOT="$T" PATH="$T/bin:$PATH" CODEX_SESSION_ID=codex-parent \
      "$N" start --lane "$lane" --provider codex --session-id codex-parent 2>&1) \
      && fail 'T7 missing --since was accepted'
  else
    out=$(HQ_ROOT="$T" PATH="$T/bin:$PATH" CODEX_SESSION_ID=codex-parent \
      "$N" start --lane "$lane" --provider codex --session-id codex-parent 2>&1) || :
  fi
  case "$out" in *--since*) : ;; *) fail 'T7 missing --since rejection did not name --since' ;; esac
  [ "$(cat "$HQ_MONITOR_COUNT" 2>/dev/null || echo 0)" -eq "$before" ] || fail 'T7 missing --since started a monitor'
  if [ "${HQ_TEST_BASELINE:-0}" != 1 ]; then
    out=$(HQ_ROOT="$T" PATH="$T/bin:$PATH" CODEX_SESSION_ID=codex-parent \
      "$N" start --lane "$lane" --provider codex --session-id codex-parent --since "$S1" 2>&1) \
      && fail 'T7 missing --round-id was accepted'
    case "$out" in *--round-id*) : ;; *) fail 'T7 missing --round-id rejection did not name --round-id' ;; esac
    [ "$(cat "$HQ_MONITOR_COUNT" 2>/dev/null || echo 0)" -eq "$before" ] || fail 'T7 missing --round-id started a monitor'
  fi
  for bad in '2026-10-10 00:00:00' '../x' '2026-10-10T00:52:21.641Z' '2026-02-30T00:00:00Z'; do
    out=$(HQ_ROOT="$T" PATH="$T/bin:$PATH" CODEX_SESSION_ID=codex-parent \
      "$N" start --lane "$lane" --provider codex --session-id codex-parent --since "$bad" --round-id "$R1" 2>&1) \
      && fail "T7 malformed --since accepted: $bad"
    case "$out" in *--since*) : ;; *) fail "T7 malformed --since rejection did not name --since: $bad" ;; esac
    [ "$(cat "$HQ_MONITOR_COUNT" 2>/dev/null || echo 0)" -eq "$before" ] || fail 'T7 malformed --since started a monitor'
  done
}
test_t8() {
  local lane=lane-probe receipt out
  prepare_lane "$lane" "$(done_lane "$lane" envelopes/001.json 2026-10-10T00:52:21.641Z)" ok
  receipt="$(receipt_for "$lane" "$S1" "$R1")"; out="$T/t8.event"
  launch_emit "$lane" "$S1" "$R1" "$out"
  finish_emit "$receipt" "$out" T8
  assert_event "$receipt" "$lane" "$S1" done done envelopes/001.json
}
# T8b: an envelope with fractional seconds in the same second as the baseline
# qualifies. A string compare would rank ".641Z" below "Z" and miss it.
test_t8b() {
  local lane=lane-probe receipt out
  prepare_lane "$lane" "$(done_lane "$lane" envelopes/001.json 2026-10-10T00:52:21.641Z)" ok
  receipt="$(receipt_for "$lane" "$S2" "$R1")"; out="$T/t8b.event"
  launch_emit "$lane" "$S2" "$R1" "$out"
  finish_emit "$receipt" "$out" T8b
  assert_event "$receipt" "$lane" "$S2" done done envelopes/001.json
}

if [ -n "${HQ_TEST_ONLY_CASE:-}" ]; then
  case "$HQ_TEST_ONLY_CASE" in
    T1) test_t1 ;;
    T2) test_t2 ;;
    T2B) test_t2b ;;
    T3) test_t3 ;;
    T3K) test_t3_one lane-killed killed ;;
    T3I) test_t3_one lane-interrupted interrupted ;;
    T4) test_t4 ;;
    T5) test_t5 ;;
    T7) test_t7 ;;
    T8) test_t8 ;;
    T8B) test_t8b ;;
    T9) test_t9 ;;
    *) fail "unknown isolated case: $HQ_TEST_ONLY_CASE" ;;
  esac
  echo "lanes-workers.test.sh: $HQ_TEST_ONLY_CASE passed"
  exit 0
fi

prepare_lane lane-probe "$(done_lane lane-probe envelopes/001.json 2026-10-10T00:52:22Z)" timeout
out="$(start_monitor lane-probe "$S1" "$R1")" || fail 'monitor start'
case "$out" in *'"monitor_id":"mon-test-1"'*) : ;; *) fail 'monitor acceptance missing' ;; esac
eq "$(tail -n 1 "$HQ_MONITOR_TARGETS")" 'session:codex:codex-parent' 'monitor target is the owning Codex session'
case "$(tail -n 1 "$HQ_MONITOR_COMMANDS")" in *emit*lane-probe*"$S1"*"$R1"*) : ;; *) fail 'monitor command missing lane, since, or round id' ;; esac
if HQ_ROOT="$T" PATH="$T/bin:$PATH" CODEX_SESSION_ID=other-parent "$N" start --lane lane-probe --provider codex --session-id codex-parent --since "$S1" --round-id "$R1" >/dev/null 2>&1; then fail 'mismatched owner accepted'; fi
if HQ_ROOT="$T" PATH="$T/bin:$PATH" CODEX_SESSION_ID=codex-parent "$N" start --lane lane-probe --provider claude --session-id codex-parent --since "$S1" --round-id "$R1" >/dev/null 2>&1; then fail 'non-Codex parent accepted'; fi
receipt="$(receipt_for lane-probe "$S1" "$R1")"; out="$T/completion.event"
launch_emit lane-probe "$S1" "$R1" "$out"; finish_emit "$receipt" "$out" completion
assert_event "$receipt" lane-probe "$S1" done done envelopes/001.json
launch_emit lane-probe "$S1" "$R1" "$T/duplicate.event" keep
poll_receipt "$receipt" || fail 'duplicate suppression receipt disappeared'
wait "$EMIT_PID" || fail 'duplicate emit did not exit successfully'
eq "$(grep -c '^CONDUCT_LANE_COMPLETE ' "$T/duplicate.event" 2>/dev/null || true)" 0 'duplicate event suppression'

mkdir -p "$T/workspace/lanes-runs/lane-fail/logs"
mkdir -p "$(monitor_lock_for lane-fail "$S1" "$R1")"
printf '99999999\n' > "$(monitor_lock_for lane-fail "$S1" "$R1")/pid"
if HQ_ROOT="$T" PATH="$T/bin:$PATH" CODEX_SESSION_ID=codex-parent HQ_MONITOR_FAIL=1 \
  "$N" start --lane lane-fail --provider codex --session-id codex-parent --since "$S1" --round-id "$R1" >/dev/null 2>&1; then
  fail 'failed monitor reported scheduled'
fi
if [ -d "$(monitor_lock_for lane-fail "$S1" "$R1")" ]; then fail 'stale startup lock was not reclaimed'; fi

test_t1; test_t2; test_t2b; test_t3; test_t4; test_t5; test_t7; test_t8; test_t8b; test_t9

case "$(cat "$ROOT/.claude/skills/conduct/dispatch.md")" in *'lanes-completion-watch.sh start'*) : ;; *) fail 'dispatch does not document Codex watcher' ;; esac
case "$(cat "$ROOT/.claude/skills/_shared/lane-dispatch-protocol.md")" in *'hq lanes wait --any'*) : ;; *) fail 'protocol does not use lane wait' ;; esac
if rg -n 'conduct-lane-notify\.sh' "$ROOT/.claude/skills/conduct/SKILL.md" "$ROOT/.claude/skills/conduct/dispatch.md" "$ROOT/.claude/skills/_shared/lane-dispatch-protocol.md"; then fail 'owned skills retained old notifier reference'; fi
echo 'lanes-workers.test.sh: role setup, templates, QA, CI, and round tracking passed'
