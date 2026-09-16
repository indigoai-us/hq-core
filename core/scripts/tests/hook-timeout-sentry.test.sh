#!/usr/bin/env bash
# Behavioral coverage for the timeout-warning watchdog. All Sentry collaborators
# are fake: the contract is the exact stdin JSON sent to `hq core sentry report`.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
GATE_SRC="$ROOT/.claude/hooks/hook-gate.sh"
MASTER_SRC="$ROOT/.claude/hooks/master-hook.sh"
WATCHDOG_SRC="$ROOT/.claude/hooks/hook-timeout-watchdog.sh"
SETTINGS_SRC="$ROOT/.claude/settings.json"
REGISTRY_SRC="$ROOT/.claude/hooks/hook-registry.json"
CODEX_CONFIG_SRC="$ROOT/.codex/config.toml"
GROK_BRIDGE_SRC="$ROOT/.grok/hooks/hq-grok-user-bridge.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_root() {
  local name="$1"
  local root="$TMP/$name"
  mkdir -p "$root/.claude/hooks" "$root/.codex" "$root/.grok/hooks" "$root/core/scripts" "$root/workspace" "$root/bin"
  cp "$SETTINGS_SRC" "$root/.claude/settings.json"
  [ ! -f "$REGISTRY_SRC" ] || cp "$REGISTRY_SRC" "$root/.claude/hooks/hook-registry.json"
  cp "$CODEX_CONFIG_SRC" "$root/.codex/config.toml"
  cp "$GROK_BRIDGE_SRC" "$root/.grok/hooks/hq-grok-user-bridge.json"
  cp "$GATE_SRC" "$root/.claude/hooks/hook-gate.sh"
  cp "$MASTER_SRC" "$root/.claude/hooks/master-hook.sh"
  # The production watchdog is copied when it exists. Leaving it absent is the
  # intended RED state for this test file against the unmodified scripts.
  [ ! -f "$WATCHDOG_SRC" ] || cp "$WATCHDOG_SRC" "$root/.claude/hooks/hook-timeout-watchdog.sh"
  printf 'hqVersion: "15.0.131"\n' > "$root/core/core.yaml"
  : > "$root/core/scripts/hook-lib.sh"
  chmod +x "$root/.claude/hooks/hook-gate.sh" "$root/.claude/hooks/master-hook.sh"
  [ ! -e "$root/.claude/hooks/hook-timeout-watchdog.sh" ] || chmod +x "$root/.claude/hooks/hook-timeout-watchdog.sh"
  cat > "$root/bin/hq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${HQ_TEST_HQ_ARGS:?}"
cat >> "${HQ_TEST_HQ_STDIN:?}"
printf '\n---EVENT---\n' >> "${HQ_TEST_HQ_STDIN:?}"
printf 'reported\n' >> "${HQ_TEST_HQ_ACK:?}"
if [ "${HQ_TEST_HQ_FAIL:-0}" = "1" ]; then
  exit 17
fi
EOF
  chmod +x "$root/bin/hq"
  : > "$root/hq.ack"
  printf '%s' "$root"
}

set_timeout() {
  local root="$1" needle="$2" timeout="$3"
  # Gated hooks declare their timeout in hook-registry.json; patch the id there
  # too so a directly-invoked gate resolves the same value.
  if [ -f "$root/.claude/hooks/hook-registry.json" ]; then
    local reg_id="${needle#*hook-gate.sh\" }"; reg_id="${reg_id%% *}"
    jq --arg id "$reg_id" --argjson timeout "$timeout" '
      .hooks |= with_entries(.value |= map(.hooks |= map(if .id == $id then .timeout = $timeout else . end)))
    ' "$root/.claude/hooks/hook-registry.json" > "$root/.claude/hooks/hook-registry.json.next"
    mv "$root/.claude/hooks/hook-registry.json.next" "$root/.claude/hooks/hook-registry.json"
  fi
  jq --arg needle "$needle" --argjson timeout "$timeout" '
    .hooks |= with_entries(
      .value |= map(
        .hooks |= map(
          if .type == "command" and (.command | contains($needle))
          then .timeout = $timeout
          else .
          end
        )
      )
    )
  ' "$root/.claude/settings.json" > "$root/.claude/settings.json.next"
  mv "$root/.claude/settings.json.next" "$root/.claude/settings.json"
}

make_gate_hook() {
  local root="$1" body="$2"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' "$body" > "$root/.claude/hooks/detect-secrets.sh"
  chmod +x "$root/.claude/hooks/detect-secrets.sh"
}

sha256_fields() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s\0' "$@" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s\0' "$@" | sha256sum | awk '{print $1}'
  else
    printf '%s\0' "$@" | openssl dgst -sha256 | awk '{print $NF}'
  fi
}

wait_for_reports() {
  local root="$1" expected="$2"
  for _ in $(seq 1 750); do
    [ "$(wc -l < "$root/hq.ack")" -ge "$expected" ] && return 0
    sleep 0.02
  done
  fail "timed out waiting for $expected reporter invocation(s)"
}

payload() {
  local session="$1"
  jq -cn --arg session "$session" '{
    hook_event_name: "PreToolUse",
    tool_name: "Bash",
    session_id: $session,
    tool_input: {command: "SUPER_SECRET_COMMAND_VALUE"}
  }'
}

payload_for_event() {
  local event="$1" session="$2"
  jq -cn --arg event "$event" --arg session "$session" '{
    hook_event_name: $event,
    tool_name: "Bash",
    session_id: $session,
    tool_input: {command: "SUPER_SECRET_COMMAND_VALUE"}
  }'
}

write_timeout_breadcrumb() {
  local root="$1" session="$2" hook_path="$3" hook_event="$4" threshold="$5"
  local session_hash breadcrumb_dir
  session_hash="$(sha256_fields "$session")"
  [ -n "$session_hash" ] || fail "could not derive SHA-256 session key for breadcrumb fixture"
  breadcrumb_dir="$root/workspace/.hook-timeout-breadcrumbs/$session_hash"
  mkdir -p "$breadcrumb_dir"
  jq -cn \
    --arg hook_path "$hook_path" \
    --arg hook_event "$hook_event" \
    --arg threshold "$threshold" \
    '{hook_path: $hook_path, hook_event: $hook_event, threshold: $threshold, elapsed_ms: 120000, declared_timeout_ms: 300000}' \
    > "$breadcrumb_dir/${threshold}-fixture.json"
}

run_gate() {
  local root="$1" session="$2" out="$3" err="$4"
  shift 4
  env \
    PATH="$root/bin:$PATH" \
    HQ_TEST_HQ_ARGS="$root/hq.args" \
    HQ_TEST_HQ_STDIN="$root/hq.stdin" \
    HQ_TEST_HQ_ACK="$root/hq.ack" \
    HQ_HOOK_TIMEOUT_SENTRY_LEAD_SECONDS=2 \
    HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$root/watchdog.trigger" \
    "$@" \
    timeout 15s bash "$root/.claude/hooks/hook-gate.sh" detect-secrets "$root/.claude/hooks/detect-secrets.sh" \
      >"$out" 2>"$err" <<<"$(payload "$session")"
}

# Fixtures reach the watchdog's deterministic test seam, then wait for the
# fake reporter's observable acknowledgement. The timeout in run_gate is only
# a diagnostic escape hatch; no assertion depends on a duration elapsing.
# shellcheck disable=SC2016 # This fixture expands when the delegated hook runs.
gate_trigger_and_wait='printf "%s\t%s\t%s\n" hook-gate "$0" relative > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"; while [ "$(wc -l < "${HQ_TEST_HQ_ACK:?}")" -lt 1 ]; do sleep 0.02; done'

event_count() {
  local root="$1"
  [ -f "$root/hq.stdin" ] || { printf '0'; return; }
  grep -c '^---EVENT---$' "$root/hq.stdin" || true
}

watchdog_running() {
  local root="$1"
  # shellcheck disable=SC2009 # Assert the exact watcher command is gone.
  ps -eo args= | grep -F "$root/.claude/hooks/hook-timeout-watchdog.sh" | grep -v grep >/dev/null
}

echo "[1] fast gate hook leaves no watcher and sends no warning"
R1="$(make_root fast)"
set_timeout "$R1" 'hook-gate.sh" detect-secrets ' 2
make_gate_hook "$R1" 'printf "fast stdout"'
run_gate "$R1" fast-session "$R1/out" "$R1/err"
[ "$(event_count "$R1")" = "0" ] || fail "fast hook emitted a timeout warning"
if watchdog_running "$R1"; then
  fail "fast hook left its spawned watchdog running"
fi
pass "fast hook has no report and reaps its watchdog"

echo "[2] slow gate hook reports exactly one flat, payload-free event"
R2="$(make_root slow)"
set_timeout "$R2" 'hook-gate.sh" detect-secrets ' 2
make_gate_hook "$R2" "$gate_trigger_and_wait; printf \"slow stdout\"; printf \"slow stderr\" >&2"
set +e
run_gate "$R2" slow-session "$R2/out" "$R2/err"
slow_gate_rc=$?
set -e
[ "$slow_gate_rc" -eq 0 ] || fail "slow gate fixture did not reach reporter acknowledgement: $slow_gate_rc"
[ "$(event_count "$R2")" = "1" ] || fail "slow hook should emit exactly one warning"
[ "$(cat "$R2/hq.args")" = 'core sentry report --timeout-ms 750' ] || fail "event fields leaked onto hq argv: $(cat "$R2/hq.args")"
jq -e '
  ([keys[]] | sort) == ["fingerprint", "level", "message", "metadata", "type"]
  and .type == "hook_timeout_warning"
  and .message == "HQ hook is approaching configured timeout"
  and (.fingerprint | startswith("hook-timeout:PreToolUse:"))
  and .level == "warning"
  and .metadata.hook_name == "detect-secrets.sh"
  and .metadata.hook_event == "PreToolUse"
  and .metadata.tool_name == "Bash"
  and .metadata.hook_path == $hook_path
  and .metadata.declared_timeout_ms == 2000
  and (.metadata.elapsed_ms | type == "number")
  and (.metadata.remaining_ms | type == "number")
  and .metadata.watchdog_timeout_ms == 0
  and .metadata.hq_version == "15.0.131"
  and .metadata.session_id == "slow-session"
  and (.metadata.platform | type == "string" and length > 0)
  and (.metadata.load_average | type == "string")
  and ([.metadata[] | type] | all(. == "string" or . == "number" or . == "boolean"))
  and (.metadata | has("hook_scope") | not)
' --arg hook_path "$R2/.claude/hooks/detect-secrets.sh" < <(sed '/^---EVENT---$/,$d' "$R2/hq.stdin") >/dev/null \
  || fail "warning omitted required safe fields or contained nested metadata"
if grep -Fq 'SUPER_SECRET_COMMAND_VALUE' "$R2/hq.stdin"; then
  fail "hook payload leaked to reporter stdin"
fi
if grep -Fq "$R2/companies/" "$R2/hq.stdin"; then
  fail "company filesystem path leaked to reporter stdin"
fi
pass "slow hook emits one flat event with the expected safe metadata"

echo "[3] watchdog preserves passing and blocking gate stdout, stderr, and exit"
for kind in passing blocking; do
  R3="$(make_root "semantics-$kind")"
  set_timeout "$R3" 'hook-gate.sh" detect-secrets ' 2
  if [ "$kind" = passing ]; then
    make_gate_hook "$R3" "$gate_trigger_and_wait; printf \"pass stdout\"; printf \"pass stderr\" >&2"
    expected_rc=0
  else
    make_gate_hook "$R3" "$gate_trigger_and_wait; printf \"block stdout\"; printf \"block stderr\" >&2; exit 2"
    expected_rc=2
  fi
  set +e
  run_gate "$R3" "with-$kind" "$R3/with.out" "$R3/with.err"
  with_rc=$?
  run_gate "$R3" "without-$kind" "$R3/without.out" "$R3/without.err" HQ_HOOK_TIMEOUT_SENTRY=0
  without_rc=$?
  set -e
  [ "$with_rc" -eq "$expected_rc" ] || fail "$kind hook changed exit with watchdog: $with_rc"
  [ "$without_rc" -eq "$expected_rc" ] || fail "$kind baseline exit wrong: $without_rc"
  [ "$(event_count "$R3")" = "1" ] || fail "$kind hook did not exercise a firing watchdog"
  cmp -s "$R3/with.out" "$R3/without.out" || fail "$kind stdout changed when watchdog fired"
  cmp -s "$R3/with.err" "$R3/without.err" || fail "$kind stderr changed when watchdog fired"
done
pass "passing and blocking hook behavior is byte-identical"

echo "[4] reporter failures fail open"
R4="$(make_root reporter-failure)"
set_timeout "$R4" 'hook-gate.sh" detect-secrets ' 2
make_gate_hook "$R4" "$gate_trigger_and_wait; printf \"reporter-safe\"; printf \"reporter-safe-err\" >&2; exit 2"
set +e
run_gate "$R4" failure-session "$R4/out" "$R4/err" HQ_TEST_HQ_FAIL=1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "failed reporter changed blocking hook exit: $rc"
[ "$(event_count "$R4")" = "1" ] || fail "failed reporter did not receive one attempted event"
[ "$(cat "$R4/out")" = 'reporter-safe' ] || fail "failed reporter changed stdout"
[ "$(cat "$R4/err")" = 'reporter-safe-err' ] || fail "failed reporter changed stderr"
set +e
run_gate "$R4" failure-baseline "$R4/baseline.out" "$R4/baseline.err" HQ_HOOK_TIMEOUT_SENTRY=0
baseline_rc=$?
set -e
[ "$baseline_rc" -eq 2 ] || fail "disabled baseline exit changed: $baseline_rc"
cmp -s "$R4/out" "$R4/baseline.out" || fail "failed reporter changed stdout versus disabled baseline"
cmp -s "$R4/err" "$R4/baseline.err" || fail "failed reporter changed stderr versus disabled baseline"
pass "failed reporter is silent and fail-open"

echo "[5] throttle suppresses a second warning for the same hook and session"
R5="$(make_root throttle)"
set_timeout "$R5" 'hook-gate.sh" detect-secrets ' 2
make_gate_hook "$R5" "$gate_trigger_and_wait"
run_gate "$R5" throttle-session "$R5/one.out" "$R5/one.err"
run_gate "$R5" throttle-session "$R5/two.out" "$R5/two.err"
[ "$(event_count "$R5")" = "1" ] || fail "throttle should suppress the second event"
pass "one warning per hook/session throttle window"

echo "[5b] cancelled watchdog removes its throttle lock"
R5_LOCK="$(make_root throttle-lock)"
set_timeout "$R5_LOCK" 'hook-gate.sh" detect-secrets ' 2
# shellcheck disable=SC2016 # This fixture expands when the delegated hook runs.
make_gate_hook "$R5_LOCK" 'printf "%s\t%s\t%s\n" hook-gate "$0" relative > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"; while [ ! -f "${HQ_HOOK_TIMEOUT_SENTRY_TEST_LOCK_READY_FILE:?}" ]; do sleep 0.02; done'
run_gate "$R5_LOCK" throttle-lock-session "$R5_LOCK/locked.out" "$R5_LOCK/locked.err" \
  HQ_HOOK_TIMEOUT_SENTRY_TEST_LOCK_READY_FILE="$R5_LOCK/lock-ready"
if find "$R5_LOCK/workspace/.hook-timeout-sentry" -name '*.lock' -type d -print -quit 2>/dev/null | grep -q .; then
  fail "cancelled watchdog left a throttle lock behind"
fi
make_gate_hook "$R5_LOCK" "$gate_trigger_and_wait"
run_gate "$R5_LOCK" throttle-lock-session "$R5_LOCK/unlocked.out" "$R5_LOCK/unlocked.err"
[ "$(event_count "$R5_LOCK")" = "1" ] || fail "cleaned throttle lock did not permit a later warning"
pass "watchdog cancellation removes its throttle lock"

echo "[6] master dispatcher remains covered outside child execution"
R6="$(make_root master-dispatch)"
set_timeout "$R6" 'master-hook.sh" PreToolUse' 3
mkdir -p "$R6/core/hooks/PreToolUse"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' > "$R6/core/hooks/PreToolUse/10-fast-child.sh"
chmod +x "$R6/core/hooks/PreToolUse/10-fast-child.sh"
cat > "$R6/bin/jq" <<'EOF'
#!/usr/bin/env bash
if mkdir "${HQ_TEST_JQ_DELAY_MARKER:?}" 2>/dev/null; then
  printf '%s\t%s\t%s\n' master-dispatch "${HQ_TEST_ROOT:?}/.claude/hooks/master-hook.sh" relative \
    > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"
  while [ "$(wc -l < "${HQ_TEST_HQ_ACK:?}")" -lt 1 ]; do
    sleep 0.02
  done
fi
exec /usr/bin/jq "$@"
EOF
chmod +x "$R6/bin/jq"
env PATH="$R6/bin:$PATH" HQ_TEST_HQ_ARGS="$R6/hq.args" HQ_TEST_HQ_STDIN="$R6/hq.stdin" HQ_TEST_HQ_ACK="$R6/hq.ack" \
  HQ_TEST_ROOT="$R6" HQ_TEST_JQ_DELAY_MARKER="$R6/jq-delayed" HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2 \
  HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$R6/watchdog.trigger" \
  timeout 15s bash "$R6/.claude/hooks/master-hook.sh" PreToolUse >"$R6/out" 2>"$R6/err" <<<"$(payload master-dispatch-session)"
[ "$(event_count "$R6")" = "1" ] || fail "slow master dispatcher should emit exactly one warning"
jq -e '
  (.fingerprint | startswith("hook-timeout:PreToolUse:"))
  and .metadata.hook_name == "master-hook.sh"
  and .metadata.hook_path == $hook_path
' --arg hook_path "$R6/.claude/hooks/master-hook.sh" < <(sed '/^---EVENT---$/,$d' "$R6/hq.stdin") >/dev/null \
  || fail "master dispatcher was not identified outside child execution"
pass "master dispatcher remains observable"

echo "[7] a master dispatch warning persists while a child is slow"
R7="$(make_root master-child)"
set_timeout "$R7" 'master-hook.sh" PreToolUse' 4
master_hook_path="$R7/.claude/hooks/master-hook.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$R7/bin/cksum"
chmod +x "$R7/bin/cksum"
mkdir -p "$R7/core/hooks/PreToolUse"
# shellcheck disable=SC2016 # This is source text for the fixture child script.
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'case "${HQ_HOOK_TIMEOUT_SENTRY:-1}" in 0) : ;; *) printf "%s\t%s\t%s\n" master-dispatch "${HQ_TEST_MASTER_PATH:?}" absolute > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"; printf "%s\t%s\t%s\n" master-dispatch "${HQ_TEST_MASTER_PATH:?}" relative >> "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"; while [ "$(wc -l < "${HQ_TEST_HQ_ACK:?}")" -lt 2 ]; do sleep 0.02; done ;; esac' 'printf "master block stdout"' 'printf "master block stderr" >&2' 'exit 2' > "$R7/core/hooks/PreToolUse/10-slow-child.sh"
chmod +x "$R7/core/hooks/PreToolUse/10-slow-child.sh"
set +e
env PATH="$R7/bin:$PATH" HQ_TEST_HQ_ARGS="$R7/hq.args" HQ_TEST_HQ_STDIN="$R7/hq.stdin" HQ_TEST_HQ_ACK="$R7/hq.ack" \
  HQ_TEST_MASTER_PATH="$master_hook_path" \
  HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=1 HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2 \
  HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$R7/watchdog.trigger" \
  timeout 15s bash "$R7/.claude/hooks/master-hook.sh" PreToolUse >"$R7/out" 2>"$R7/err" <<<"$(payload master-session)"
with_master_rc=$?
env PATH="$R7/bin:$PATH" HQ_TEST_HQ_ARGS="$R7/hq.args" HQ_TEST_HQ_STDIN="$R7/hq.stdin" HQ_TEST_HQ_ACK="$R7/hq.ack" \
  HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=1 HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2 \
  HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$R7/watchdog.trigger" \
  timeout 15s bash "$R7/.claude/hooks/master-hook.sh" PreToolUse >"$R7/without.out" 2>"$R7/without.err" <<<"$(payload master-without-session)"
without_master_rc=$?
set -e
[ "$with_master_rc" -eq 2 ] || fail "master child changed blocking exit with watchdog: $with_master_rc"
[ "$without_master_rc" -eq 2 ] || fail "master child baseline exit wrong: $without_master_rc"
cmp -s "$R7/out" "$R7/without.out" || fail "master child stdout changed when watchdog fired"
cmp -s "$R7/err" "$R7/without.err" || fail "master child stderr changed when watchdog fired"
[ "$(event_count "$R7")" = "2" ] || fail "slow master child should emit both master warnings once"
jq -e '
  (.fingerprint | startswith("hook-timeout:PreToolUse:"))
  and .metadata.hook_name == "master-hook.sh"
  and .metadata.hook_path == $hook_path
' --arg hook_path "$master_hook_path" < <(sed '/^---EVENT---$/,$d' "$R7/hq.stdin") >/dev/null \
  || fail "master warning did not identify its dispatcher"

breadcrumb="$(find "$R7/workspace/.hook-timeout-breadcrumbs" -name '*.json' -type f | head -n 1)"
[ -n "$breadcrumb" ] || fail "slow master child did not persist a breadcrumb"
breadcrumb_session_key="$(basename "$(dirname "$breadcrumb")")"
[[ "$breadcrumb_session_key" =~ ^[a-f0-9]{64}$ ]] \
  || fail "master breadcrumb session key is not a SHA-256 digest"
jq -e --arg hook_path "$master_hook_path" '
  .hook_path == $hook_path and .hook_event == "PreToolUse" and (.elapsed_ms | type == "number")
' "$breadcrumb" >/dev/null || fail "breadcrumb did not name the exact slow child"

# The following fire is deliberately fast. It must consume the persisted
# breadcrumb into the existing additionalContext aggregation, then never repeat
# that warning after consumption.
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s\n" "{\"hookSpecificOutput\":{\"additionalContext\":\"existing child context\"}}"' > "$R7/core/hooks/PreToolUse/10-slow-child.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s\n" "{\"decision\":\"block\",\"reason\":\"fixture block\"}"' > "$R7/core/hooks/PreToolUse/20-blocker.sh"
chmod +x "$R7/core/hooks/PreToolUse/20-blocker.sh"
PATH="$R7/bin:$PATH" HQ_TEST_HQ_ARGS="$R7/hq.args" HQ_TEST_HQ_STDIN="$R7/hq.stdin" \
  HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=1 HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2 \
  bash "$R7/.claude/hooks/master-hook.sh" PreToolUse >"$R7/blocked.out" 2>"$R7/blocked.err" <<<"$(payload master-session)"
jq -e '(.decision == "block") and (.hookSpecificOutput.hqSessionBlockedBy | endswith("20-blocker.sh"))' "$R7/blocked.out" >/dev/null \
  || fail "blocking child did not preserve master block output"
if grep -Fq "$R7/core/hooks/PreToolUse/10-slow-child.sh" "$R7/blocked.out"; then
  fail "warning was mixed into a block response instead of staying pending"
fi
[ "$(find "$R7/workspace/.hook-timeout-breadcrumbs" -name '*.json' -type f | wc -l)" -ge 1 ] \
  || fail "blocking child consumed a warning that was not emitted"
[ ! -s "$R7/blocked.err" ] || fail "blocking child changed master stderr"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' ':' > "$R7/core/hooks/PreToolUse/20-blocker.sh"
PATH="$R7/bin:$PATH" HQ_TEST_HQ_ARGS="$R7/hq.args" HQ_TEST_HQ_STDIN="$R7/hq.stdin" \
  HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=1 HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2 \
  bash "$R7/.claude/hooks/master-hook.sh" PreToolUse >"$R7/injected.out" 2>"$R7/injected.err" <<<"$(payload master-session)"
jq -e --arg hook_path "$master_hook_path" '
  .hookSpecificOutput.hookEventName == "PreToolUse"
  and (.hookSpecificOutput.additionalContext as $context
  | ($context | contains($hook_path))
  and ($context | contains("This hook is taking too long; investigate why."))
  and ($context | contains("about to be killed by the harness"))
  and ($context | index("taking too long") < index("about to be killed"))
  and ($context | endswith("existing child context")))
' "$R7/injected.out" >/dev/null || fail "next master fire did not prepend the breadcrumb to additionalContext"
grep -Fq '"hookEventName":"PreToolUse"' "$R7/injected.out" \
  || fail "PreToolUse injection did not write hookEventName to stdout"
[ ! -s "$R7/injected.err" ] || fail "breadcrumb injection changed master stderr"

PATH="$R7/bin:$PATH" HQ_TEST_HQ_ARGS="$R7/hq.args" HQ_TEST_HQ_STDIN="$R7/hq.stdin" \
  HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=1 HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2 \
  bash "$R7/.claude/hooks/master-hook.sh" PreToolUse >"$R7/consumed.out" 2>"$R7/consumed.err" <<<"$(payload master-session)"
jq -e '
  .hookSpecificOutput.additionalContext == "existing child context"
' "$R7/consumed.out" >/dev/null || fail "consumed breadcrumb was injected a second time"
[ ! -s "$R7/consumed.err" ] || fail "consumed breadcrumb changed master stderr"

disabled_session_hash="$(sha256_fields master-session)"
disabled_breadcrumb_dir="$R7/workspace/.hook-timeout-breadcrumbs/$disabled_session_hash"
mkdir -p "$disabled_breadcrumb_dir"
jq -cn --arg hook_path "$master_hook_path" '
  {hook_path: $hook_path, hook_event: "PreToolUse", threshold: "absolute", elapsed_ms: 1000, declared_timeout_ms: 4000}
' > "$disabled_breadcrumb_dir/absolute-disabled.json"
PATH="$R7/bin:$PATH" HQ_TEST_HQ_ARGS="$R7/hq.args" HQ_TEST_HQ_STDIN="$R7/hq.stdin" \
  HQ_DISABLED_HOOKS='another-hook, hook-timeout-sentry' \
  bash "$R7/.claude/hooks/master-hook.sh" PreToolUse >"$R7/disabled-injection.out" 2>"$R7/disabled-injection.err" <<<"$(payload master-session)"
jq -e '.hookSpecificOutput.additionalContext == "existing child context"' "$R7/disabled-injection.out" >/dev/null \
  || fail "spaced HQ_DISABLED_HOOKS did not suppress breadcrumb injection"
[ -f "$disabled_breadcrumb_dir/absolute-disabled.json" ] || fail "spaced HQ_DISABLED_HOOKS consumed a breadcrumb"
pass "master dispatch breadcrumb is injected once ahead of existing context"

echo "[7b] master emits an event-tagged warning even with no child JSON"
mkdir -p "$R7/core/hooks/SessionStart"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' > "$R7/core/hooks/SessionStart/10-no-json-child.sh"
chmod +x "$R7/core/hooks/SessionStart/10-no-json-child.sh"
session_start_path="$R7/core/hooks/SessionStart/10-no-json-child.sh"
session_start_id="session-start-warning"
session_start_hash="$(sha256_fields "$session_start_id")"
session_start_dir="$R7/workspace/.hook-timeout-breadcrumbs/$session_start_hash"
mkdir -p "$session_start_dir"
jq -cn --arg hook_path "$session_start_path" '
  {hook_path: $hook_path, hook_event: "SessionStart", threshold: "absolute", elapsed_ms: 120000, declared_timeout_ms: 300000}
' > "$session_start_dir/absolute-no-json.json"
PATH="$R7/bin:$PATH" HQ_TEST_HQ_ARGS="$R7/hq.args" HQ_TEST_HQ_STDIN="$R7/hq.stdin" \
  bash "$R7/.claude/hooks/master-hook.sh" SessionStart >"$R7/no-json-warning.out" 2>"$R7/no-json-warning.err" \
    <<<"$(jq -cn --arg session "$session_start_id" '{hook_event_name: "SessionStart", session_id: $session}')"
jq -e --arg hook_path "$session_start_path" '
  .hookSpecificOutput.hookEventName == "SessionStart"
  and (.hookSpecificOutput.additionalContext | contains($hook_path))
  and (.hookSpecificOutput.additionalContext | contains("This hook is taking too long; investigate why."))
' "$R7/no-json-warning.out" >/dev/null || fail "no-JSON SessionStart fire did not emit its warning object"
grep -Fq '"hookEventName":"SessionStart"' "$R7/no-json-warning.out" \
  || fail "SessionStart injection did not write hookEventName to stdout"
[ ! -s "$R7/no-json-warning.err" ] || fail "no-JSON warning changed master stderr"
pass "warnings reach stdout with hookEventName for two event types"

echo "[7c] non-delivering lifecycle events retain breadcrumbs for a delivering fire"
for non_delivering_event in Stop SubagentStop SessionEnd Notification PreCompact; do
  R7_EVENT="$(make_root "pending-${non_delivering_event}")"
  pending_session="pending-${non_delivering_event}-session"
  pending_hook_path="$R7_EVENT/personal/hooks/$non_delivering_event/99-pending-child.sh"
  write_timeout_breadcrumb "$R7_EVENT" "$pending_session" "$pending_hook_path" "$non_delivering_event" absolute
  pending_hash="$(sha256_fields "$pending_session")"
  pending_record="$R7_EVENT/workspace/.hook-timeout-breadcrumbs/$pending_hash/absolute-fixture.json"
  env PATH="$R7_EVENT/bin:$PATH" HQ_TEST_HQ_ARGS="$R7_EVENT/hq.args" HQ_TEST_HQ_STDIN="$R7_EVENT/hq.stdin" HQ_TEST_HQ_ACK="$R7_EVENT/hq.ack" \
    bash "$R7_EVENT/.claude/hooks/master-hook.sh" "$non_delivering_event" >"$R7_EVENT/non-delivering.out" 2>"$R7_EVENT/non-delivering.err" \
      <<<"$(payload_for_event "$non_delivering_event" "$pending_session")"
  [ -f "$pending_record" ] || fail "$non_delivering_event consumed a breadcrumb without delivering additionalContext"
  if grep -Fq "$pending_hook_path" "$R7_EVENT/non-delivering.out"; then
    fail "$non_delivering_event emitted additionalContext instead of retaining it"
  fi
  [ ! -s "$R7_EVENT/non-delivering.err" ] || fail "$non_delivering_event changed master stderr"
  env PATH="$R7_EVENT/bin:$PATH" HQ_TEST_HQ_ARGS="$R7_EVENT/hq.args" HQ_TEST_HQ_STDIN="$R7_EVENT/hq.stdin" HQ_TEST_HQ_ACK="$R7_EVENT/hq.ack" \
    bash "$R7_EVENT/.claude/hooks/master-hook.sh" UserPromptSubmit >"$R7_EVENT/delivering.out" 2>"$R7_EVENT/delivering.err" \
      <<<"$(payload_for_event UserPromptSubmit "$pending_session")"
  [ "$(grep -oF "$pending_hook_path" "$R7_EVENT/delivering.out" | wc -l)" -eq 1 ] \
    || fail "$non_delivering_event breadcrumb was not delivered exactly once on UserPromptSubmit"
  [ ! -f "$pending_record" ] || fail "$non_delivering_event breadcrumb remained after delivering fire"
  [ ! -s "$R7_EVENT/delivering.err" ] || fail "UserPromptSubmit delivery after $non_delivering_event changed master stderr"
done
pass "all non-delivering lifecycle events defer breadcrumbs to UserPromptSubmit"

echo "[8] a killed master dispatcher leaves a durable breadcrumb for the next fire"
R8K="$(make_root killed-child)"
set_timeout "$R8K" 'master-hook.sh" PreToolUse' 3
master_hook_path="$R8K/.claude/hooks/master-hook.sh"
mkdir -p "$R8K/core/hooks/PreToolUse"
# shellcheck disable=SC2016 # This is source text for the fixture child script.
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s\n" "$$" > "$HQ_TEST_CHILD_PID"' 'printf "%s\t%s\t%s\n" master-dispatch "${HQ_TEST_MASTER_PATH:?}" absolute > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"' 'printf "%s\t%s\t%s\n" master-dispatch "${HQ_TEST_MASTER_PATH:?}" relative >> "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"' 'while [ "$(wc -l < "${HQ_TEST_HQ_ACK:?}")" -lt 2 ]; do sleep 0.02; done' 'exec sleep 10' > "$R8K/core/hooks/PreToolUse/10-killed-child.sh"
chmod +x "$R8K/core/hooks/PreToolUse/10-killed-child.sh"
env PATH="$R8K/bin:$PATH" HQ_TEST_HQ_ARGS="$R8K/hq.args" HQ_TEST_HQ_STDIN="$R8K/hq.stdin" HQ_TEST_HQ_ACK="$R8K/hq.ack" \
  HQ_TEST_CHILD_PID="$R8K/child.pid" HQ_TEST_MASTER_PATH="$master_hook_path" HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=1 HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=1 \
  HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$R8K/watchdog.trigger" \
  bash "$R8K/.claude/hooks/master-hook.sh" PreToolUse >"$R8K/killed.out" 2>"$R8K/killed.err" <<<"$(payload killed-session)" &
master_pid=$!
for _ in $(seq 1 750); do
  [ -s "$R8K/child.pid" ] && break
  sleep 0.02
done
[ -s "$R8K/child.pid" ] || fail "killed-child fixture did not start"
wait_for_reports "$R8K" 2
child_pid="$(cat "$R8K/child.pid")"
kill -KILL "$child_pid" "$master_pid" >/dev/null 2>&1 || true
set +e
wait "$master_pid" 2>/dev/null
set -e
killed_breadcrumb_dir="$R8K/workspace/.hook-timeout-breadcrumbs"
killed_child_path="$master_hook_path"
killed_breadcrumb=""
pending_child_breadcrumbs=0
for candidate in "$killed_breadcrumb_dir"/*/*.json; do
  [ -f "$candidate" ] || continue
  if jq -e --arg hook_path "$killed_child_path" '.hook_path == $hook_path' "$candidate" >/dev/null 2>&1; then
    pending_child_breadcrumbs=$((pending_child_breadcrumbs + 1))
    if jq -e '.threshold == "absolute"' "$candidate" >/dev/null 2>&1; then
      killed_breadcrumb="$candidate"
    fi
  fi
done
[ -n "$killed_breadcrumb" ] || fail "killed dispatcher did not leave an absolute watchdog breadcrumb"
[ "$pending_child_breadcrumbs" -ge 1 ] || fail "killed dispatcher breadcrumb did not name the master hook"

printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s\n" "{\"hookSpecificOutput\":{\"additionalContext\":\"post-kill child context\"}}"' > "$R8K/core/hooks/PreToolUse/10-killed-child.sh"
recovery_pids=()
for label in first second; do
  PATH="$R8K/bin:$PATH" HQ_TEST_HQ_ARGS="$R8K/hq.args" HQ_TEST_HQ_STDIN="$R8K/hq.stdin" \
    HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=1 HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=1 \
    bash "$R8K/.claude/hooks/master-hook.sh" PreToolUse >"$R8K/$label.out" 2>"$R8K/$label.err" <<<"$(payload killed-session)" &
  recovery_pids+=("$!")
done
set +e
wait "${recovery_pids[0]}"
first_rc=$?
wait "${recovery_pids[1]}"
second_rc=$?
set -e
[ "$first_rc" -eq 0 ] && [ "$second_rc" -eq 0 ] || fail "concurrent breadcrumb consumers changed master exits"
injected_count="$(grep -ohF "$killed_child_path" "$R8K/first.out" "$R8K/second.out" | wc -l)"
[ "$injected_count" -eq "$pending_child_breadcrumbs" ] || fail "concurrent fires double-injected or dropped dispatcher breadcrumbs: expected $pending_child_breadcrumbs, got $injected_count"
for label in first second; do
  jq -e '.hookSpecificOutput.additionalContext | contains("post-kill child context")' "$R8K/$label.out" >/dev/null \
    || fail "concurrent $label fire produced corrupt or partial output"
  [ ! -s "$R8K/$label.err" ] || fail "concurrent $label fire changed stderr"
done
pass "killed dispatcher warning survives and concurrent fires claim it once"

echo "[8b] master watchdogs do not report after an early dispatcher death"
R8_EARLY="$(make_root early-master-death)"
set_timeout "$R8_EARLY" 'master-hook.sh" PreToolUse' 3
mkdir -p "$R8_EARLY/core/hooks/PreToolUse"
# shellcheck disable=SC2016 # This is source text for the fixture child script.
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s\n" "$$" > "$HQ_TEST_CHILD_PID"' 'exec sleep 10' > "$R8_EARLY/core/hooks/PreToolUse/10-early-killed-child.sh"
chmod +x "$R8_EARLY/core/hooks/PreToolUse/10-early-killed-child.sh"
env PATH="$R8_EARLY/bin:$PATH" HQ_TEST_HQ_ARGS="$R8_EARLY/hq.args" HQ_TEST_HQ_STDIN="$R8_EARLY/hq.stdin" HQ_TEST_HQ_ACK="$R8_EARLY/hq.ack" \
  HQ_TEST_CHILD_PID="$R8_EARLY/child.pid" HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$R8_EARLY/watchdog.trigger" \
  bash "$R8_EARLY/.claude/hooks/master-hook.sh" PreToolUse >"$R8_EARLY/out" 2>"$R8_EARLY/err" <<<"$(payload early-death-session)" &
early_master_pid=$!
for _ in $(seq 1 750); do
  [ -s "$R8_EARLY/child.pid" ] && break
  sleep 0.02
done
[ -s "$R8_EARLY/child.pid" ] || fail "early-death fixture did not start"
early_child_pid="$(cat "$R8_EARLY/child.pid")"
kill -KILL "$early_child_pid" "$early_master_pid" >/dev/null 2>&1 || true
set +e
wait "$early_master_pid" 2>/dev/null
set -e
printf '%s\t%s\t%s\n' master-dispatch "$R8_EARLY/.claude/hooks/master-hook.sh" absolute > "$R8_EARLY/watchdog.trigger"
printf '%s\t%s\t%s\n' master-dispatch "$R8_EARLY/.claude/hooks/master-hook.sh" relative >> "$R8_EARLY/watchdog.trigger"
for _ in $(seq 1 750); do
  watchdog_running "$R8_EARLY" || break
  sleep 0.02
done
if watchdog_running "$R8_EARLY"; then
  fail "master watchdog survived after its dispatcher died before the threshold"
fi
[ "$(event_count "$R8_EARLY")" = "0" ] || fail "early-dead master watchdog emitted a report"
if find "$R8_EARLY/workspace/.hook-timeout-breadcrumbs" -name '*.json' -type f -print -quit 2>/dev/null | grep -q .; then
  fail "early-dead master watchdog wrote a breadcrumb"
fi
pass "early master death leaves no late report or breadcrumb"

echo "[9] feature switch disables both watchdog channels"
R9="$(make_root disabled)"
set_timeout "$R9" 'hook-gate.sh" detect-secrets ' 2
make_gate_hook "$R9" ':'
run_gate "$R9" disabled-session "$R9/out" "$R9/err" HQ_HOOK_TIMEOUT_SENTRY=0 \
  HQ_HOOK_TIMEOUT_SENTRY_TEST_ARMED_FILE="$R9/armed"
[ "$(event_count "$R9")" = "0" ] || fail "disable switch still sent a warning"
[ ! -e "$R9/armed" ] || fail "disable switch still armed a watchdog"
if watchdog_running "$R9"; then
  fail "disable switch still spawned a watchdog"
fi
R9_LIST="$(make_root disabled-list)"
set_timeout "$R9_LIST" 'hook-gate.sh" detect-secrets ' 2
make_gate_hook "$R9_LIST" ':'
run_gate "$R9_LIST" disabled-list-session "$R9_LIST/out" "$R9_LIST/err" \
  HQ_DISABLED_HOOKS='another-hook, hook-timeout-sentry' \
  HQ_HOOK_TIMEOUT_SENTRY_TEST_ARMED_FILE="$R9_LIST/armed"
[ "$(event_count "$R9_LIST")" = "0" ] || fail "spaced HQ_DISABLED_HOOKS still sent a warning"
[ ! -e "$R9_LIST/armed" ] || fail "spaced HQ_DISABLED_HOOKS still armed a watchdog"
if watchdog_running "$R9_LIST"; then
  fail "spaced HQ_DISABLED_HOOKS still spawned a watchdog"
fi
pass "both disable switches, including spaced HQ_DISABLED_HOOKS, fully opt out"

echo "[10] missing and older hq CLIs fail open silently"
R10="$(make_root missing-hq)"
set_timeout "$R10" 'hook-gate.sh" detect-secrets ' 2
# shellcheck disable=SC2016 # This fixture expands when the delegated hook runs.
make_gate_hook "$R10" 'printf "%s\t%s\t%s\n" hook-gate "$0" relative > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"; while [ ! -f "${HQ_TEST_HQ_OLD_ATTEMPT:?}" ]; do sleep 0.02; done; printf "missing-hq-out"; printf "missing-hq-err" >&2; exit 2'
cat > "$R10/bin/hq" <<'EOF'
#!/usr/bin/env bash
# Simulates an installed pre-feature client which rejects the new subcommand.
touch "${HQ_TEST_HQ_OLD_ATTEMPT:?}"
cat >/dev/null
exit 2
EOF
chmod +x "$R10/bin/hq"
set +e
env PATH="$R10/bin:/usr/bin:/bin" HQ_TEST_HQ_ARGS="$R10/hq.args" HQ_TEST_HQ_STDIN="$R10/hq.stdin" HQ_TEST_HQ_ACK="$R10/hq.ack" \
  HQ_TEST_HQ_OLD_ATTEMPT="$R10/old-cli-attempt" HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$R10/watchdog.trigger" \
  HQ_HOOK_TIMEOUT_SENTRY_LEAD_SECONDS=2 \
  timeout 15s bash "$R10/.claude/hooks/hook-gate.sh" detect-secrets "$R10/.claude/hooks/detect-secrets.sh" \
    >"$R10/old-cli.out" 2>"$R10/old-cli.err" <<<"$(payload old-cli-session)"
old_cli_rc=$?
env PATH="$R10/bin:/usr/bin:/bin" HQ_TEST_HQ_ARGS="$R10/hq.args" HQ_TEST_HQ_STDIN="$R10/hq.stdin" HQ_TEST_HQ_ACK="$R10/hq.ack" \
  HQ_TEST_HQ_OLD_ATTEMPT="$R10/old-cli-attempt" HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$R10/watchdog.trigger" \
  HQ_HOOK_TIMEOUT_SENTRY=0 \
  timeout 15s bash "$R10/.claude/hooks/hook-gate.sh" detect-secrets "$R10/.claude/hooks/detect-secrets.sh" \
    >"$R10/baseline.out" 2>"$R10/baseline.err" <<<"$(payload old-cli-baseline-session)"
baseline_rc=$?
set -e
[ "$old_cli_rc" -eq 2 ] || fail "older hq changed blocking hook exit: $old_cli_rc"
[ "$baseline_rc" -eq 2 ] || fail "disabled baseline exit changed: $baseline_rc"
cmp -s "$R10/old-cli.out" "$R10/baseline.out" || fail "older hq changed stdout"
cmp -s "$R10/old-cli.err" "$R10/baseline.err" || fail "older hq changed stderr"
mv "$R10/bin/hq" "$R10/bin/not-hq"
make_gate_hook "$R10" 'printf "missing-hq-out"; printf "missing-hq-err" >&2; exit 2'
set +e
env PATH="$R10/bin:/usr/bin:/bin" HQ_TEST_HQ_ARGS="$R10/hq.args" HQ_TEST_HQ_STDIN="$R10/hq.stdin" HQ_TEST_HQ_ACK="$R10/hq.ack" \
  HQ_HOOK_TIMEOUT_SENTRY_LEAD_SECONDS=2 \
  timeout 15s bash "$R10/.claude/hooks/hook-gate.sh" detect-secrets "$R10/.claude/hooks/detect-secrets.sh" \
    >"$R10/missing.out" 2>"$R10/missing.err" <<<"$(payload missing-hq-session)"
missing_rc=$?
set -e
[ "$missing_rc" -eq 2 ] || fail "missing hq changed blocking hook exit: $missing_rc"
cmp -s "$R10/missing.out" "$R10/baseline.out" || fail "missing hq changed stdout"
cmp -s "$R10/missing.err" "$R10/baseline.err" || fail "missing hq changed stderr"
[ "$(event_count "$R10")" = "0" ] || fail "missing hq unexpectedly recorded a report"
pass "older and missing hq CLIs are byte-identical to the disabled baseline"

echo "[11] master warning falls back safely without settings.json"
R11="$(make_root master-no-settings)"
mv "$R11/.claude/settings.json" "$R11/.claude/settings.json.unavailable"
mkdir -p "$R11/personal/hooks/PostToolUse"
# shellcheck disable=SC2016 # This is source text for the fixture child script.
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'while [ "$(wc -l < "${HQ_TEST_HQ_ACK:?}")" -lt 1 ]; do sleep 0.02; done' 'printf "fallback child complete"' > "$R11/personal/hooks/PostToolUse/99-my-slow-hook.sh"
chmod +x "$R11/personal/hooks/PostToolUse/99-my-slow-hook.sh"
printf '%s\t%s\t%s\n' master-dispatch "$R11/.claude/hooks/master-hook.sh" absolute > "$R11/watchdog.trigger"
set +e
env PATH="$R11/bin:$PATH" HQ_TEST_HQ_ARGS="$R11/hq.args" HQ_TEST_HQ_STDIN="$R11/hq.stdin" HQ_TEST_HQ_ACK="$R11/hq.ack" \
  HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=2 HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$R11/watchdog.trigger" \
  timeout 15s bash "$R11/.claude/hooks/master-hook.sh" PostToolUse >"$R11/out" 2>"$R11/err" <<<"$(jq -cn --arg session no-settings-session '{hook_event_name: "PostToolUse", tool_name: "Bash", session_id: $session}')"
no_settings_rc=$?
set -e
[ "$no_settings_rc" -eq 0 ] || fail "master without settings.json did not reach reporter acknowledgement: $no_settings_rc"
[ "$(event_count "$R11")" = "1" ] || fail "master without settings.json did not emit one warning"
[ "$(cat "$R11/out")" = 'fallback child complete' ] || fail "master without settings.json changed stdout"
[ ! -s "$R11/err" ] || fail "master without settings.json changed stderr"
fallback_breadcrumb="$(find "$R11/workspace/.hook-timeout-breadcrumbs" -name '*.json' -type f | head -n 1)"
[ -n "$fallback_breadcrumb" ] || fail "master without settings.json did not write a breadcrumb"
jq -e --arg hook_path "$R11/.claude/hooks/master-hook.sh" '
  .metadata.hook_path == $hook_path
  and .metadata.hook_name == "master-hook.sh"
  and .metadata.hook_event == "PostToolUse"
  and .metadata.declared_timeout_ms == 30000
  and .metadata.watchdog_timeout_ms == 2000
' < <(sed '/^---EVENT---$/,$d' "$R11/hq.stdin") >/dev/null \
  || fail "missing settings.json did not use the documented timeout fallback"
pass "master watchdog uses the 30-second fallback without settings.json"

echo "[12] Codex gate warnings use the active Codex registration deadline"
R12_CODEX="$(make_root codex-timeout)"
# Make the Claude registration deliberately different. A Codex fire must read
# .codex/config.toml's 30s PreToolUse registration instead of this 300s value.
set_timeout "$R12_CODEX" 'hook-gate.sh" detect-secrets ' 300
make_gate_hook "$R12_CODEX" "$gate_trigger_and_wait"
run_gate "$R12_CODEX" codex-timeout-session "$R12_CODEX/out" "$R12_CODEX/err" HQ_HARNESS=codex
[ "$(event_count "$R12_CODEX")" = "1" ] || fail "Codex gate fixture did not report exactly one warning"
jq -e '
  .metadata.declared_timeout_ms == 30000
  and .metadata.watchdog_timeout_ms == 28000
' < <(sed '/^---EVENT---$/,$d' "$R12_CODEX/hq.stdin") >/dev/null \
  || fail "Codex gate warning did not use .codex/config.toml's timeout"
pass "Codex gate watchdog reads its active harness registration"

echo "[13] Grok master-child warnings use the active Grok bridge deadline"
R13_GROK="$(make_root grok-timeout)"
grok_child_path="$R13_GROK/personal/hooks/PostToolUse/99-grok-child.sh"
mkdir -p "$(dirname "$grok_child_path")"
: > "$grok_child_path"
printf '%s\t%s\t%s\n' master-child "$grok_child_path" relative > "$R13_GROK/watchdog.trigger"
env PATH="$R13_GROK/bin:$PATH" HQ_TEST_HQ_ARGS="$R13_GROK/hq.args" HQ_TEST_HQ_STDIN="$R13_GROK/hq.stdin" HQ_TEST_HQ_ACK="$R13_GROK/hq.ack" \
  HQ_HARNESS=grok HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2 \
  HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$R13_GROK/watchdog.trigger" \
  timeout 15s bash "$R13_GROK/.claude/hooks/hook-timeout-watchdog.sh" \
    --root "$R13_GROK" --source master-child --hook-path "$grok_child_path" \
    --event PostToolUse --threshold relative --started-at 0 \
    <<<"$(payload_for_event PostToolUse grok-timeout-session)" \
    >"$R13_GROK/out" 2>"$R13_GROK/err"
[ "$(event_count "$R13_GROK")" = "1" ] || fail "Grok master-child fixture did not report exactly one warning"
jq -e '
  .metadata.declared_timeout_ms == 120000
  and .metadata.watchdog_timeout_ms == 118000
' < <(sed '/^---EVENT---$/,$d' "$R13_GROK/hq.stdin") >/dev/null \
  || fail "Grok master-child warning did not use .grok/hooks/hq-grok-user-bridge.json's timeout"
pass "Grok master-child watchdog reads its active harness registration"

echo "ALL PASS: hook-timeout-sentry"
