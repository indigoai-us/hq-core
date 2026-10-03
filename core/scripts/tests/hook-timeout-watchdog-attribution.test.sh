#!/usr/bin/env bash
# HQ_CLI_REQUIRED_IN_CI: the real sentry-report probes below must run in CI.
set -euo pipefail
unset HQ_ROOT

ROOT="$(git rev-parse --show-toplevel)"
ORIGINAL_PATH="$PATH"
CASE="${C179_TEST_CASE:-all}"
SHELL_FAMILY="$(uname -s)"
case "$SHELL_FAMILY" in
  MINGW*|MSYS*|CYGWIN*)
    if command -v cygpath >/dev/null 2>&1; then
      ROOT="$(cygpath -u "$ROOT")"
    fi
    ;;
esac
TMP="$(mktemp -d "$ROOT/.c179-attribution.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SYSTEM_JQ="$(command -v jq)"
SYSTEM_AWK="$(command -v awk)"
REAL_HQ_BIN="$(command -v hq 2>/dev/null || true)"
HQ_CLI_CONTRACT_AVAILABLE=0
HQ_CLI_DEBUG_CONTEXT_ENABLED=0
TIMEOUT_MODE=perl
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"
timeout_version=""
if [ "${C179_TEST_FORCE_PERL_TIMEOUT:-0}" != "1" ]; then
  if [ -n "$TIMEOUT_BIN" ]; then
    timeout_version="$("$TIMEOUT_BIN" --version 2>/dev/null || true)"
  fi
  case "$timeout_version" in
    *"GNU coreutils"*) TIMEOUT_MODE=gnu ;;
    *)
      # Git Bash can have GNU timeout.exe even when Windows' native timeout.exe
      # shadows it earlier on PATH.
      for candidate in /usr/bin/timeout.exe /usr/bin/timeout /bin/timeout.exe /bin/timeout; do
        [ -x "$candidate" ] || continue
        candidate_version="$("$candidate" --version 2>/dev/null || true)"
        case "$candidate_version" in
          *"GNU coreutils"*) TIMEOUT_MODE=gnu; TIMEOUT_BIN="$candidate"; break ;;
        esac
      done
      ;;
  esac
fi

fixture_path() {
  local path="$1"
  case "$SHELL_FAMILY" in
    MINGW*|MSYS*|CYGWIN*)
      if command -v cygpath >/dev/null 2>&1; then
        path="$(cygpath -u "$path")"
      fi
      ;;
  esac
  printf '%s' "$path"
}

# Hook fixtures invoke `timeout` internally. Keep that command available on
# macOS and Git Bash using the same bounded Perl fallback as the shared suite.
if [ "$TIMEOUT_MODE" = gnu ]; then
  export HQ_TEST_GNU_TIMEOUT_BIN="$TIMEOUT_BIN"
  cat > "$TMP/timeout-bin" <<'EOF'
#!/usr/bin/env bash
exec "${HQ_TEST_GNU_TIMEOUT_BIN:?}" "$@"
EOF
else
  if ! command -v perl >/dev/null 2>&1; then
    printf '%s\n' 'FAIL: neither GNU timeout nor Perl is available for bounded attribution tests' >&2
    exit 1
  fi
  cat > "$TMP/timeout-bin" <<'EOF'
#!/usr/bin/env bash
seconds="${1%s}"
shift
exec perl -e 'alarm shift; exec @ARGV or exit 127' "$seconds" "$@"
EOF
fi
chmod +x "$TMP/timeout-bin"
mkdir -p "$TMP/bin"
mv "$TMP/timeout-bin" "$TMP/bin/timeout"
PATH="$TMP/bin:$PATH"
export PATH

run_bounded() {
  local seconds="$1"
  shift
  if [ "$TIMEOUT_MODE" = gnu ]; then
    "$TIMEOUT_BIN" "${seconds}s" "$@"
  else
    perl -e 'alarm shift; exec @ARGV or exit 127' "$seconds" "$@"
  fi
}

run_fixture_bounded() {
  local seconds="$1" env_assignment
  shift
  local -a env_args=() cmd_args=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    env_args+=("$1")
    shift
  done
  [ "$#" -gt 0 ] || fail 'run_fixture_bounded needs -- before the command'
  shift
  cmd_args=("$@")
  (
    for env_assignment in "${env_args[@]}"; do
      export "${env_assignment?}"
    done
    case "$SHELL_FAMILY" in
      MINGW*|MSYS*|CYGWIN*)
        "$TMP/bin/timeout" "${seconds}s" "${cmd_args[@]}"
        ;;
      *)
        run_bounded "$seconds" "${cmd_args[@]}"
        ;;
    esac
  )
}

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

sha256_fields() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s\0' "$@" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s\0' "$@" | sha256sum | awk '{print $1}'
  else
    printf '%s\0' "$@" | openssl dgst -sha256 | awk '{print $NF}'
  fi
}

prepare_fixture() {
  local root="$TMP/$1"
  mkdir -p "$root/.claude/hooks" "$root/.codex" "$root/.grok/hooks" "$root/core/scripts/lib" \
    "$root/core" "$root/bin" "$root/workspace/.hook-timeout-journal"
  cp "$ROOT/.claude/hooks/master-hook.sh" "$root/.claude/hooks/master-hook.sh"
  cp "$ROOT/.claude/hooks/hook-gate.sh" "$root/.claude/hooks/hook-gate.sh"
  cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$root/.claude/hooks/hook-timeout-probe.sh"
  cp "$ROOT/.claude/hooks/hook-timeout-watchdog.sh" "$root/.claude/hooks/hook-timeout-watchdog.sh"
  cp "$ROOT/.claude/hooks/hook-registry.json" "$root/.claude/hooks/hook-registry.json"
  cp "$ROOT/.claude/settings.json" "$root/.claude/settings.json"
  cp "$ROOT/.codex/config.toml" "$root/.codex/config.toml"
  cp "$ROOT/.grok/hooks/hq-grok-user-bridge.json" "$root/.grok/hooks/hq-grok-user-bridge.json"
  cp "$ROOT/core/scripts/resolve-hq-root.sh" "$root/core/scripts/resolve-hq-root.sh"
  cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$root/core/scripts/lib/hook-adapter-core.sh"
  printf 'hqVersion: "15.0.176-beta.7"\n' > "$root/core/core.yaml"
  chmod +x "$root/.claude/hooks/master-hook.sh" "$root/.claude/hooks/hook-gate.sh"
  cat > "$root/bin/awk" <<'AWK'
#!/usr/bin/env bash
if [ -n "${HQ_TEST_PHASE_TIMING_TRIGGER_FILE:-}" ]; then
  for argument in "$@"; do
    if [ "$argument" = "$HQ_TEST_PHASE_TIMING_TRIGGER_FILE" ] \
      && [ ! -e "${HQ_TEST_PHASE_SWITCHED:-}" ]; then
      printf 'output_write\t2\t\n' > "$HQ_TEST_PHASE_TIMING_FILE"
      : > "${HQ_TEST_PHASE_SWITCHED:?}"
      break
    fi
  done
fi
exec "${HQ_TEST_SYSTEM_AWK:?}" "$@"
AWK
  chmod +x "$root/bin/awk"
  cat > "$root/bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'hq 5.229.1\n'
  exit 0
fi
cat >> "${HQ_TEST_EVENT_FILE:?}"
printf '\n---EVENT---\n' >> "${HQ_TEST_EVENT_FILE:?}"
if [ -n "${HQ_TEST_ORDER_AT_REPORT:-}" ] \
  && [ ! -e "$HQ_TEST_ORDER_AT_REPORT" ] \
  && [ -f "${HQ_TEST_ORDER:-}" ]; then
  cat "$HQ_TEST_ORDER" > "$HQ_TEST_ORDER_AT_REPORT"
fi
if [ -n "${HQ_TEST_REPORT_TIMESTAMP:-}" ]; then
  date +%s > "$HQ_TEST_REPORT_TIMESTAMP"
fi
if [ -n "${HQ_TEST_RELEASE_FILE:-}" ]; then
  : > "$HQ_TEST_RELEASE_FILE"
fi
if [ -n "${HQ_TEST_REPORT_ACK:-}" ]; then
  : > "$HQ_TEST_REPORT_ACK"
fi
HQ
  chmod +x "$root/bin/hq" "$root/.claude/hooks/hook-timeout-watchdog.sh"
  printf '%s' "$root"
}

fixture_timeout_seconds() {
  case "${C179_TEST_SHELL_FAMILY:-$SHELL_FAMILY}" in
    MINGW*|MSYS*|CYGWIN*) printf '20' ;;
    *) printf '10' ;;
  esac
}

run_report() {
  local root="$1" label="$2" session="c179-attribution-$2" invocation="c179-test-$2"
  local hook_path="$root/.claude/hooks/master-hook.sh" fixture_bin
  fixture_bin="$(fixture_path "$root/bin")"
  printf 'master-dispatch\t%s\tabsolute\n' "$hook_path" > "$root/trigger.tsv"
  run_fixture_bounded "$(fixture_timeout_seconds)" \
    "PATH=$fixture_bin:$PATH" \
    'BASH_ENV=' \
    'HQ_HOOK_TIMEOUT_SENTRY=1' \
    'HQ_DISABLED_HOOKS=' \
    "HQ_TEST_SYSTEM_AWK=$SYSTEM_AWK" \
    "HQ_TEST_PHASE_TIMING_FILE=${C179_TEST_PHASE_TIMING_FILE:-}" \
    "HQ_TEST_PHASE_TIMING_TRIGGER_FILE=${C179_TEST_PHASE_TIMING_TRIGGER_FILE:-}" \
    "HQ_TEST_PHASE_SWITCHED=$root/phase-switched" \
    "HQ_TEST_REPORT_ACK=${C179_TEST_REPORT_ACK:-}" \
    "HQ_TEST_EVENT_FILE=$root/event.jsonl" \
    "HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE=$root/trigger.tsv" \
    "HQ_HOOK_TIMEOUT_SENTRY_TEST_STATUS_FILE=$root/watchdog.status" \
    -- bash "$root/.claude/hooks/hook-timeout-watchdog.sh" \
      --root "$root" --source master-dispatch --hook-path "$hook_path" \
      --event SessionStart --threshold absolute --started-at 0 \
      --invocation-id "$invocation" \
      <<<"{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$session\"}" \
      > "$root/out" 2> "$root/err"
  [ -s "$root/event.jsonl" ] || {
    printf 'watchdog status: %s\n' "$(cat "$root/watchdog.status" 2>/dev/null || true)" >&2
    cat "$root/err" >&2
    fail "$label watchdog did not report"
  }
  [ ! -s "$root/err" ] || fail "$label watchdog wrote to stderr"
  sed '/^---EVENT---$/,$d' "$root/event.jsonl" > "$root/event.json"
}

prepare_master_phase_fixture() {
  local root="$1" with_children="${2:-yes}"
  mkdir -p "$root/core/hooks/SessionStart"
  cat > "$root/bin/jq" <<'JQ'
#!/usr/bin/env bash
if [ "${HQ_TEST_REQUIRE_EARLY_PHASE:-0}" = 1 ] \
  && { [ "${1:-}" = "-r" ] || [ "${1:-}" = "-j" ]; } \
  && [ "${2:-}" = "--arg" ] \
  && [ "${3:-}" = "ev" ]; then
  early_phase=""
  for early_phase_file in "${HQ_TEST_EARLY_PHASE_DIR:?}"/*.debug.tsv.active; do
    [ -r "$early_phase_file" ] || continue
    IFS=$'\t' read -r early_phase _ < "$early_phase_file" || early_phase=""
    break
  done
  if [ "$early_phase" = startup ] || [ "$early_phase" = parse ]; then
    : > "${HQ_TEST_EARLY_PHASE_SEEN:?}"
  else
    : > "${HQ_TEST_EARLY_PHASE_MISSING:?}"
  fi
fi
if [ "${HQ_TEST_DELAY_PRECHILD:-0}" = 1 ] \
  && [ "${1:-}" = "-j" ] \
  && [ "${2:-}" = "--arg" ] \
  && [ "${3:-}" = "ev" ]; then
  sleep 2
fi
if [ "${1:-}" = "-e" ] && [ "${2:-}" = 'type == "object"' ]; then
  input="$(cat)"
  case "$input" in
    *C179_PHASE_DELAY*)
      printf 'triggered\n' > "${HQ_TEST_JQ_DELAYED:?}"
      if [ "${HQ_HOOK_TIMEOUT_SENTRY:-1}" != 0 ]; then
        printf 'master-dispatch\t%s\tabsolute\n' "${HQ_TEST_MASTER_PATH:?}" \
          > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"
        acknowledged=0
        for _ in {1..1500}; do
          if [ -e "${HQ_TEST_JQ_ACK:?}" ]; then
            acknowledged=1
            break
          fi
          sleep 0.02
        done
        if [ "$acknowledged" -ne 1 ]; then
          : > "${HQ_TEST_JQ_ACK_TIMEOUT:?}"
          exit 93
        fi
      fi
      ;;
  esac
  printf '%s' "$input" | "$HQ_TEST_SYSTEM_JQ" "$@"
  exit $?
fi
exec "$HQ_TEST_SYSTEM_JQ" "$@"
JQ
  chmod +x "$root/bin/jq"
  [ "$with_children" = yes ] || return 0
  cat > "$root/core/hooks/SessionStart/10-slow-json.sh" <<'CHILD'
#!/usr/bin/env bash
cat > "${HQ_TEST_CAPTURED_INPUT:?}"
printf 'first\n' >> "${HQ_TEST_ORDER:?}"
printf '%s' '{"hookSpecificOutput":{"additionalContext":"C179_PHASE_DELAY"}}'
CHILD
  cat > "$root/core/hooks/SessionStart/20-later.sh" <<'CHILD'
#!/usr/bin/env bash
cat >/dev/null
if [ "${HQ_HOOK_TIMEOUT_SENTRY:-1}" != "0" ]; then
  for _ in {1..500}; do
    [ -e "${HQ_TEST_RELEASE_FILE:?}" ] && break
    sleep 0.02
  done
  [ -e "$HQ_TEST_RELEASE_FILE" ] || exit 91
fi
printf 'second\n' >> "${HQ_TEST_ORDER:?}"
printf 'later child output'
CHILD
  chmod +x "$root/core/hooks/SessionStart/10-slow-json.sh" "$root/core/hooks/SessionStart/20-later.sh"
}

run_master_phase_case() {
  local root="$1" sentry="$2" label="$3" with_children="${4:-yes}" child_timeout="${5:-}" \
    session_id="${6-c179-master-phase-delay-$3}" rc expected_payload payload fixture_bin
  fixture_bin="$(fixture_path "$root/bin")"
  mkdir -p "$root/home"
  : > "$root/order"
  expected_payload="{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$session_id\"}"
  payload="$expected_payload"$'\n\n'
  set +e
  run_fixture_bounded 45 \
    "PATH=$fixture_bin:$PATH" \
    "BASH_ENV=${C179_TEST_BASH_ENV:-}" \
    'SECONDS=0' \
    'HQ_HARNESS=codex' \
    "HOME=$root/home" \
    'HQ_DISABLED_HOOKS=' \
    "HQ_HOOK_TIMEOUT_SENTRY=$sentry" \
    "HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE=$root/watchdog.trigger" \
    "HQ_HOOK_TIMEOUT_SENTRY_TEST_STATUS_FILE=$root/watchdog.status" \
    "HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=${C179_TEST_MASTER_ABSOLUTE_SECONDS:-2}" \
    'HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=20' \
    "HQ_TEST_DELAY_PRECHILD=${C179_TEST_DELAY_PRECHILD:-0}" \
    "HQ_TEST_SYSTEM_JQ=$SYSTEM_JQ" \
    "HQ_TEST_SYSTEM_AWK=$SYSTEM_AWK" \
    "HQ_TEST_REQUIRE_EARLY_PHASE=$sentry" \
    "HQ_TEST_EARLY_PHASE_DIR=$root/workspace/.hook-timeout-journal" \
    "HQ_TEST_EARLY_PHASE_SEEN=$root/early-phase-seen" \
    "HQ_TEST_EARLY_PHASE_MISSING=$root/early-phase-missing" \
    "HQ_TEST_EVENT_FILE=$root/event.jsonl" \
    "HQ_TEST_ORDER=$root/order" \
    "HQ_TEST_CAPTURED_INPUT=$root/captured-input" \
    "HQ_TEST_ORDER_AT_REPORT=$root/order-at-report" \
    "HQ_TEST_FIRST_CHILD_STARTED=$root/first-child-started" \
    "HQ_TEST_SECOND_CHILD_STARTED=$root/second-child-started" \
    "HQ_TEST_REPORT_TIMESTAMP=$root/report-timestamp" \
    "HQ_TEST_RELEASE_FILE=$root/report-released" \
    "HQ_TEST_JQ_ACK=$root/jq-ack" \
    "HQ_TEST_JQ_ACK_TIMEOUT=$root/jq-ack-timeout" \
    "HQ_TEST_REPORT_ACK=$root/jq-ack" \
    "HQ_TEST_JQ_DELAYED=$root/jq-delayed" \
    "HQ_TEST_MASTER_PATH=$root/.claude/hooks/master-hook.sh" \
    ${child_timeout:+"HQ_MASTER_CHILD_TIMEOUT=$child_timeout"} \
    -- bash "$root/.claude/hooks/master-hook.sh" SessionStart \
    > "$root/out" 2> "$root/err" \
    <<<"$payload"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && { [ -z "$child_timeout" ] || [ "$rc" -ne 124 ]; }; then
    fail "$label master hook returned $rc"
  fi
  [ ! -e "$root/jq-ack-timeout" ] || fail "$label timed out waiting for the mocked reporter acknowledgement"
  if [ "$sentry" = 1 ]; then
    [ -e "$root/early-phase-seen" ] || {
      printf 'early phase files:\n' >&2
      ls -l "$root/workspace/.hook-timeout-journal" >&2 || true
      for early_phase_file in "$root/workspace/.hook-timeout-journal"/*.debug.tsv.active; do
        [ -r "$early_phase_file" ] && { printf '%s: ' "$early_phase_file" >&2; cat "$early_phase_file" >&2; }
      done
      fail "$label master phase file did not exist before initial payload parsing"
    }
    [ ! -e "$root/early-phase-missing" ] || fail "$label master phase file held no active phase before payload parsing"
  fi
  printf '%s' "$expected_payload" > "$root/expected-input"
  if [ "$with_children" = single-slow ]; then
    cmp -s "$root/expected-input" "$root/captured-input" \
      || fail "$label SessionStart hook did not receive the payload"
    [ "$(cat "$root/order")" = first ] || fail "$label did not dispatch the slow fixture child"
  elif [ "$with_children" = yes ]; then
    cmp -s "$root/expected-input" "$root/captured-input" \
      || fail "$label SessionStart stdin differed from command-substitution semantics"
    [ "$(cat "$root/order")" = $'first\nsecond' ] || fail "$label did not dispatch both children in order"
  else
    [ ! -s "$root/order" ] || fail "$label unexpectedly dispatched a child"
  fi
  [ ! -s "$root/err" ] || { cat "$root/err" >&2; fail "$label master hook changed stderr"; }
}

seed_sequence() {
  local root="$1" session="$2" session_hash
  session_hash="$(sha256_fields "$session")"
  printf '%s\n' \
    'fast-child.sh	SessionStart	5' \
    'slow-a.sh	SessionStart	12000' \
    'slow-b.sh	SessionStart	9000' \
    'slow-c.sh	SessionStart	8000' \
    'fourth.sh	SessionStart	7000' \
    > "$root/workspace/.hook-timeout-journal/$session_hash.tsv"
}

test_windows_slow_start_budget() {
  local rc
  C179_TEST_SHELL_FAMILY=MSYS_NT
  set +e
  run_fixture_bounded "$(fixture_timeout_seconds)" -- bash -c 'sleep 11'
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "Windows-simulated slow startup exceeded the fixture budget (rc=$rc)"
  pass "Windows-simulated slow startup stays within the platform fixture budget"
}

test_slow_child_tag() {
  local root session session_hash invocation active_file child_started_ms
  root="$(prepare_fixture slow-child)"
  session="c179-attribution-slow-child"
  invocation="c179-test-slow-child"
  session_hash="$(sha256_fields "$session")"
  active_file="$root/workspace/.hook-timeout-journal/$session_hash.tsv.$invocation.active"
  child_started_ms="$(( $(date +%s) * 1000 - 1000 ))"
  printf 'slow-session-child.sh\tSessionStart\t%s\n' "$child_started_ms" > "$active_file"
  seed_sequence "$root" "$session"
  run_report "$root" slow-child
  jq -e '
    .type == "hook_timeout_warning"
    and .metadata.slow_child == "slow-session-child.sh"
    and (.metadata.slow_child_ms | type == "number" and . > 0)
    and (.metadata | has("slow_child_ms_bucket") | not)
  ' "$root/event.json" >/dev/null || { jq -c '.metadata' "$root/event.json" >&2; fail "slow child tag or CLI-derived duration was missing"; }
  pass "running child name and elapsed milliseconds are reported without an unsupported bucket"
}

test_session_start_mesh_hook_debug_name() {
  local debug_context
  debug_context="$(bash -c '. "$1"; hook_timeout_debug_context_json master-hook.sh SessionStart 30000 5000 25000 "[]" child_wait "$2" 500' \
    _ "$ROOT/.claude/hooks/hook-timeout-probe.sh" '35-work-mesh-session-start.sh')"
  printf '%s' "$debug_context" | jq -e '
    .waiting_child_basename == "35-work-mesh-session-start.sh"
    and .waiting_child_elapsed_ms == 500
  ' >/dev/null \
    || { printf '%s\n' "$debug_context" >&2; fail "SessionStart mesh child was not retained as a safe debug name"; }
  pass "SessionStart mesh child keeps a safe basename in timeout debug context"
}

test_master_phase_tag() {
  local root session session_hash invocation active_phase_file
  root="$(prepare_fixture master-phase)"
  session="c179-attribution-master-phase"
  invocation="c179-test-master-phase"
  session_hash="$(sha256_fields "$session")"
  active_phase_file="$root/workspace/.hook-timeout-journal/$invocation.debug.tsv.active"
  printf 'parse\t1\t\n' > "$active_phase_file"
  seed_sequence "$root" "$session"
  run_report "$root" master-phase
  jq -e '
    .type == "hook_timeout_warning"
    and (.metadata | has("slow_child") | not)
    and .metadata.hook_timeout_debug_context.wait_point == "parse"
    and (.metadata | has("slow_child_ms_bucket") | not)
  ' "$root/event.json" >/dev/null || { jq -c '.metadata' "$root/event.json" >&2; fail "active master phase was not kept in the debug wait point"; }
  pass "active master phase is reported through the CLI-supported debug wait point"
}

test_watchdog_trigger_phase_snapshot() {
  local root invocation debug_file active_file
  root="$(prepare_fixture watchdog-trigger-phase-snapshot)"
  invocation=c179-test-trigger-phase-snapshot
  debug_file="$root/workspace/.hook-timeout-journal/$invocation.debug.tsv"
  active_file="$debug_file.active"
  printf 'external_command\t1\t\n' > "$active_file"
  : > "$debug_file"
  C179_TEST_PHASE_TIMING_FILE="$active_file"
  C179_TEST_PHASE_TIMING_TRIGGER_FILE="$debug_file"
  run_report "$root" trigger-phase-snapshot
  unset C179_TEST_PHASE_TIMING_FILE C179_TEST_PHASE_TIMING_TRIGGER_FILE
  [ -e "$root/phase-switched" ] || fail "phase snapshot fixture did not change the phase after trigger acceptance"
  jq -e '.metadata.slow_phase == "external_command"' "$root/event.json" >/dev/null \
    || { jq -c '.metadata | {slow_phase, hook_timeout_debug_context}' "$root/event.json" >&2; fail "watchdog warning omitted its allowlisted trigger-time slow phase"; }
  jq -e '.metadata.hook_timeout_debug_context.wait_point == "external_command"' \
    "$root/event.json" >/dev/null \
    || { jq -c '.metadata.hook_timeout_debug_context' "$root/event.json" >&2; fail "watchdog used report-time phase instead of trigger-time snapshot"; }
  pass "watchdog snapshots the active master phase at trigger acceptance"
}

test_eof_read_under_errexit() {
  local root fixture_bin payload rc
  root="$(prepare_fixture read-eof-errexit)"
  mkdir -p "$root/core/hooks/SessionStart"
  cat > "$root/.claude/hooks/hook-registry.json" <<'JSON'
{"hooks":{}}
JSON
  cat > "$root/core/hooks/SessionStart/10-eof-marker.sh" <<'CHILD'
#!/usr/bin/env bash
cat > "${HQ_TEST_CAPTURED_INPUT:?}"
: > "${HQ_TEST_HOOK_MARKER:?}"
printf 'eof-hook-ran'
CHILD
  chmod +x "$root/core/hooks/SessionStart/10-eof-marker.sh"
  fixture_bin="$(fixture_path "$root/bin")"
  payload='{"hook_event_name":"SessionStart","session_id":"c179-read-eof-errexit"}'
  set +e
  run_bounded 15 env SHELLOPTS=errexit "PATH=$fixture_bin:$PATH" BASH_ENV= \
    HQ_HOOK_TIMEOUT_SENTRY=0 HQ_DISABLED_HOOKS= \
    "HQ_TEST_SYSTEM_AWK=$SYSTEM_AWK" \
    "HQ_TEST_CAPTURED_INPUT=$root/captured-input" "HQ_TEST_HOOK_MARKER=$root/hook-ran" \
    bash -x "$root/.claude/hooks/master-hook.sh" SessionStart \
    <<<"$payload" > "$root/out" 2> "$root/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$root/err" "$root/out" >&2; fail "master dispatcher returned $rc with inherited errexit"; }
  [ -e "$root/hook-ran" ] || fail "master dispatcher exited before running the SessionStart hook"
  printf '%s' "$payload" > "$root/expected-input"
  cmp -s "$root/expected-input" "$root/captured-input" || fail "SessionStart hook did not receive the EOF-terminated payload"
  grep -q 'eof-hook-ran' "$root/out" || fail "SessionStart hook output was not composed"
  pass "EOF status does not abort the dispatcher under inherited errexit"
}

test_master_late_active_phase() {
  local root function_file
  root="$(prepare_fixture master-late-active-phase)"
  function_file="$root/master-report-late-function.sh"
  awk '
    /^master_report_late_event\(\) \{/ { copy = 1 }
    copy { print }
    copy && /^}/ { exit }
  ' "$ROOT/.claude/hooks/master-hook.sh" > "$function_file"
  [ -s "$function_file" ] || fail "master_report_late_event function was not extracted"
  (
    . "$root/.claude/hooks/hook-timeout-probe.sh"
    . "$function_file"
    # These globals are read by the dynamically sourced master-hook function.
    # shellcheck disable=SC2034
    REPO_ROOT="$root"
    # shellcheck disable=SC2034
    SCRIPT_DIR="$root/.claude/hooks"
    # shellcheck disable=SC2034
    EVENT=SessionStart
    # shellcheck disable=SC2034
    TOOL_NAME=Bash
    # shellcheck disable=SC2034
    SESSION_ID=c179-master-late-active-phase
    # shellcheck disable=SC2034
    MASTER_TIMING_PRECISION=ms
    MASTER_DEBUG_ACTIVE_PHASE=external_command
    MASTER_DEBUG_ACTIVE_STARTED=1
    MASTER_DEBUG_PHASE_FILE="$root/master.debug.tsv"
    MASTER_DEBUG_ACTIVE_PHASE_FILE="$root/master.debug.tsv.active"
    MASTER_DEBUG_CLI_VERSION_FILE="$root/master.debug.tsv.cli-version"
    # shellcheck disable=SC2034 # Read by the dynamically sourced master-hook function.
    MASTER_DEBUG_CHILD_PHASE_FILE=""
    # shellcheck disable=SC2034 # Read by the dynamically sourced master-hook function.
    MASTER_DEBUG_CHILD_ACTIVE_PHASE_FILE=""
    # shellcheck disable=SC2034
    timeout_journal_file="$root/workspace/.hook-timeout-journal/session.tsv"
    # shellcheck disable=SC2034
    completed_child_elapsed_ms=()
    # shellcheck disable=SC2034
    completed_child_paths=()
    master_safe_hook_script() { printf 'master-hook.sh'; }
    master_load_average() { printf '0.1'; }
    master_spawn_probe_ms() { printf 'unavailable'; }
    master_hook_fingerprint_identity() { printf '%s' "$1"; }
    master_timeout_sha256() { printf 'c179-test-fingerprint'; }
    master_bash_env_state() { printf 'unset'; }
    master_shell_descriptor() { printf 'bash test'; }
    master_cwd_kind() { printf 'hq-root'; }
    master_nproc() { printf '2'; }
    master_hook_sequence_json() { printf '[]'; }
    master_policy_trigger_metadata_json() { printf '{}'; }
    master_declared_timeout_ms() { printf '30000'; }
    master_watchdog_timeout_ms() { printf '10000'; }
    hook_timeout_cli_supports_debug_context() { return 0; }
    hook_timeout_windows_process_count() { printf 'unavailable'; }
    PATH="$root/bin:$PATH"
    HQ_TEST_EVENT_FILE="$root/event.jsonl"
    export PATH HQ_TEST_EVENT_FILE
    master_report_late_event hook_late_finish "$root/.claude/hooks/master-hook.sh" 5000 0
    MASTER_DEBUG_ACTIVE_PHASE='../../unlisted/path'
    HQ_TEST_EVENT_FILE="$root/untrusted-phase-event.jsonl"
    export HQ_TEST_EVENT_FILE
    master_report_late_event hook_late_finish "$root/.claude/hooks/master-hook.sh" 5000 0
  ) || fail "master late report fixture failed"
  sed '/^---EVENT---$/,$d' "$root/event.jsonl" > "$root/event.json"
  jq -e '
    .type == "hook_late_finish"
    and (.metadata | has("slow_child") | not)
    and .metadata.slow_phase == "external_command"
    and .metadata.hook_timeout_debug_context.wait_point == "external_command"
  ' "$root/event.json" >/dev/null || {
    jq -c '.metadata | {slow_child, slow_phase, hook_timeout_debug_context}' "$root/event.json" >&2
    fail "master late report lost the active external_command phase"
  }
  pass "master late report with no slow child retains the active phase"
  sed '/^---EVENT---$/,$d' "$root/untrusted-phase-event.jsonl" > "$root/untrusted-phase-event.json"
  jq -e '
    (.metadata | has("slow_phase") | not)
    and .metadata.hook_timeout_debug_context.wait_point == "wait"
  ' "$root/untrusted-phase-event.json" >/dev/null || {
    jq -c '.metadata | {slow_phase, hook_timeout_debug_context}' "$root/untrusted-phase-event.json" >&2
    fail "master late report emitted an unlisted phase"
  }
  if grep -Fq '../../unlisted/path' "$root/untrusted-phase-event.json"; then
    fail "master late report leaked an unlisted phase value"
  fi
  pass "master late report omits phase values outside the fixed list"
}

portable_ms_timestamp() {
  local realtime seconds fractional now
  realtime="${EPOCHREALTIME:-}"
  if [[ "$realtime" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    seconds="${BASH_REMATCH[1]}"
    fractional="${BASH_REMATCH[2]}000"
    fractional="${fractional:0:3}"
    printf '%s%s\n' "$seconds" "$fractional"
    return 0
  fi
  now="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$now" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$now"
    return 0
  fi
  seconds="$(date +%s)"
  [[ "$seconds" =~ ^[0-9]+$ ]] || return 1
  printf '%s000\n' "$seconds"
}

test_master_dispatch_startup_elapsed() {
  local root event first_started second_started report_started startup_child_elapsed_ms child_elapsed_ms hook_elapsed_ms wall_started_ms wall_finished_ms wall_span_ms
  root="$(prepare_fixture master-dispatch-startup-elapsed)"
  prepare_master_phase_fixture "$root" no
  cat > "$root/core/hooks/SessionStart/10-first-delayed.sh" <<'CHILD'
#!/usr/bin/env bash
cat > "${HQ_TEST_CAPTURED_INPUT:?}"
printf 'first\n' >> "${HQ_TEST_ORDER:?}"
date +%s > "${HQ_TEST_FIRST_CHILD_STARTED:?}"
sleep 5
printf '%s' '{"hookSpecificOutput":{"additionalContext":"first child completed"}}'
CHILD
  cat > "$root/core/hooks/SessionStart/20-second-slow.sh" <<'CHILD'
#!/usr/bin/env bash
cat >/dev/null
printf 'second\n' >> "${HQ_TEST_ORDER:?}"
date +%s > "${HQ_TEST_SECOND_CHILD_STARTED:?}"
sleep 0.75
printf 'master-dispatch\t%s\tabsolute\n' "${HQ_TEST_MASTER_PATH:?}" > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"
for _ in {1..500}; do
  [ -e "${HQ_TEST_RELEASE_FILE:?}" ] && break
  sleep 0.02
done
[ -e "$HQ_TEST_RELEASE_FILE" ] || exit 91
printf '%s' '{"hookSpecificOutput":{"additionalContext":"second child completed"}}'
CHILD
  chmod +x "$root/core/hooks/SessionStart/10-first-delayed.sh" "$root/core/hooks/SessionStart/20-second-slow.sh"
  wall_started_ms="$(portable_ms_timestamp)" || fail "could not read a portable start timestamp"
  C179_TEST_DELAY_PRECHILD=1 C179_TEST_MASTER_ABSOLUTE_SECONDS=5 \
    run_master_phase_case "$root" 1 dispatch-startup-elapsed yes "" c179-dispatch-startup-elapsed
  wall_finished_ms="$(portable_ms_timestamp)" || fail "could not read a portable finish timestamp"
  unset C179_TEST_DELAY_PRECHILD C179_TEST_MASTER_ABSOLUTE_SECONDS
  event="$(sed '/^---EVENT---$/d' "$root/event.jsonl" | jq -sc '[.[] | select(.type == "hook_timeout_warning" or .type == "hook_timeout_exceeded")][0] // empty')"
  [ -n "$event" ] || { cat "$root/event.jsonl" >&2; fail "dispatcher startup fixture emitted no timeout report"; }
  first_started="$(cat "$root/first-child-started")"
  second_started="$(cat "$root/second-child-started")"
  report_started="$(cat "$root/report-timestamp")"
  startup_child_elapsed_ms="$(jq -r '[.metadata.hook_timeout_debug_context.phase_timings[] | select(.phase == "startup" or .phase == "external_command") | .elapsed_ms] | add' <<<"$event")"
  child_elapsed_ms="$(jq -r '[.metadata.hook_timeout_debug_context.phase_timings[] | select(.phase == "external_command") | .elapsed_ms] | add // 0' <<<"$event")"
  hook_elapsed_ms="$(jq -r '.metadata.hook_timeout_debug_context.elapsed_ms' <<<"$event")"
  [[ "$wall_started_ms" =~ ^[0-9]+$ && "$wall_finished_ms" =~ ^[0-9]+$ ]] \
    || fail "dispatcher fixture did not record a numeric wall-clock span"
  wall_span_ms=$((wall_finished_ms - wall_started_ms))
  [ "$wall_span_ms" -ge 0 ] || fail "dispatcher fixture wall-clock span moved backwards"
  [[ "$first_started" =~ ^[0-9]+$ && "$second_started" =~ ^[0-9]+$ && "$report_started" =~ ^[0-9]+$ ]] \
    || fail "dispatcher fixture did not record ordered launch and report timestamps"
  [ "$first_started" -lt "$second_started" ] && [ "$second_started" -le "$report_started" ] \
    || fail "dispatcher report did not follow the first and second child launches"
  jq -e '
    .metadata.hook_timeout_debug_context.wait_point == "external_command"
    and .metadata.hook_timeout_debug_context.waiting_child_basename == "20-second-slow.sh"
    and (.metadata.hook_timeout_debug_context.waiting_child_elapsed_ms | type == "number" and floor == . and . >= 500)
    and any(.metadata.hook_timeout_debug_context.phase_timings[];
      .phase == "external_command" and (.elapsed_ms | type == "number" and floor == . and . >= 500))
    and any(.metadata.hook_timeout_debug_context.phase_timings[];
      .phase == "startup" and (.elapsed_ms | type == "number" and floor == . and . >= 1500))
  ' <<<"$event" >/dev/null || {
    jq -c '.metadata.hook_timeout_debug_context' <<<"$event" >&2
    fail "dispatcher report omitted bounded phase, child, elapsed, or startup measurements"
  }
  if [ "$child_elapsed_ms" -gt "$((hook_elapsed_ms + 1000))" ]; then
    printf 'children=%s hook_elapsed=%s startup+children=%s wall_span=%s first=%s second=%s report=%s\n' \
      "$child_elapsed_ms" "$hook_elapsed_ms" "$startup_child_elapsed_ms" "$wall_span_ms" \
      "$first_started" "$second_started" "$report_started" >&2
    jq -c '.metadata.hook_timeout_debug_context.phase_timings' <<<"$event" >&2
    fail "child timing exceeds watchdog elapsed time"
  fi
  if [ "$startup_child_elapsed_ms" -gt "$((wall_span_ms + 1000))" ]; then
    printf 'startup+child=%s hook_elapsed=%s wall_span=%s first=%s second=%s report=%s\n' \
      "$startup_child_elapsed_ms" "$hook_elapsed_ms" "$wall_span_ms" \
      "$first_started" "$second_started" "$report_started" >&2
    jq -c '.metadata.hook_timeout_debug_context.phase_timings' <<<"$event" >&2
    fail "startup timing overlaps child runtime instead of ending at the first launch"
  fi
  pass "dispatcher reports pre-child startup separately from a delayed first child and second-child wait"
}

test_journal_sequence_filter() {
  local root session session_hash journal long_script long_prefix expected entry i
  root="$(prepare_fixture journal-sequence-filter)"
  session=c179-journal-filter
  session_hash="$(sha256_fields "$session")"
  journal="$root/workspace/.hook-timeout-journal/$session_hash.tsv"
  long_script=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
  long_prefix="$(printf '%s' "$long_script" | cut -c1-48)"
  : > "$journal"
  for ((i = 1; i <= 22; i++)); do
    printf 'valid-%02d.sh\tSessionStart\t%s\n' "$i" "$i" >> "$journal"
  done
  printf '%s\tSessionStart\t23\n' "$long_script" >> "$journal"
  printf 'bad script.sh\tSessionStart\t24\n' >> "$journal"
  printf 'bad/name.sh\tSessionStart\t25\n' >> "$journal"
  printf 'too-slow.sh\tSessionStart\t86400001\n' >> "$journal"
  (
    . "$root/.claude/hooks/hook-timeout-probe.sh"
    if declare -F hook_timeout_sequence_json >/dev/null 2>&1; then
      hook_timeout_sequence_json "$journal"
    else
      eval "$(awk '
        /^hook_sequence_json\(\) \{/ { copy = 1 }
        copy { print }
        copy && /^}/ { exit }
      ' "$root/.claude/hooks/hook-timeout-watchdog.sh")"
      root="$root"
      # shellcheck disable=SC2034
      session_id="$session"
      hook_sequence_json
    fi
  ) > "$root/sequence.json"
  expected='['
  for ((i = 4; i <= 22; i++)); do
    [ "$i" -eq 4 ] || expected="$expected,"
    entry="$(jq -cn --arg script "$(printf 'valid-%02d.sh' "$i")" --argjson ms "$i" '{script:$script,event:"SessionStart",ms:$ms}')"
    expected="$expected$entry"
  done
  entry="$(jq -cn --arg script "$long_prefix" --argjson ms 23 '{script:$script,event:"SessionStart",ms:$ms}')"
  expected="$expected,$entry]"
  if ! jq -e --argjson expected "$expected" '. == $expected' "$root/sequence.json" >/dev/null; then
    jq -c . "$root/sequence.json" >&2
    fail "journal filter accepted unsafe or out-of-range rows, failed to truncate a long script, or did not keep the last 20 valid rows"
  fi
  pass "journal filter rejects invalid rows, truncates script names, and keeps the last 20 valid entries"
}

test_hook_sequence_array() {
  local root session
  root="$(prepare_fixture hook-sequence)"
  session="c179-attribution-hook-sequence"
  seed_sequence "$root" "$session"
  run_report "$root" hook-sequence
  jq -e '
    .metadata.hook_sequence == [
      {script:"fast-child.sh", event:"SessionStart", ms:5},
      {script:"slow-a.sh", event:"SessionStart", ms:12000},
      {script:"slow-b.sh", event:"SessionStart", ms:9000},
      {script:"slow-c.sh", event:"SessionStart", ms:8000},
      {script:"fourth.sh", event:"SessionStart", ms:7000}
    ]
    and (.metadata.hook_sequence | type == "array" and length <= 20)
  ' "$root/event.json" >/dev/null || { jq -c '.metadata' "$root/event.json" >&2; fail "hook sequence was not the bounded CLI contract array"; }
  pass "hook sequence keeps the CLI bounded array contract"
}

contract_cli_probe() {
  local probe debug_probe
  if [ -z "$REAL_HQ_BIN" ]; then
    if [ "${HQ_CLI_REQUIRED_IN_CI:-0}" = "1" ]; then
      fail "HQ_CLI_REQUIRED_IN_CI=1: hq executable is required but missing"
    fi
    return 0
  fi
  probe='{"type":"hook_timeout","message":"m","fingerprint":"f","level":"warning","metadata":{"hook_sequence":[{"script":"a.sh","event":"PreToolUse","ms":5}]}}'
  if printf '%s\n' "$probe" | run_bounded 15 "$REAL_HQ_BIN" core sentry report --dry-run > "$TMP/hq-cli-probe.out" 2> "$TMP/hq-cli-probe.err" \
    && jq -e '.extra.hook_sequence == [{script:"a.sh",event:"PreToolUse",ms:5}]' "$TMP/hq-cli-probe.out" >/dev/null 2>&1; then
    HQ_CLI_CONTRACT_AVAILABLE=1
  else
    if [ "${HQ_CLI_REQUIRED_IN_CI:-0}" = "1" ]; then
      fail "HQ_CLI_REQUIRED_IN_CI=1: hq core sentry report --dry-run probe failed or returned unexpected JSON"
    fi
    return 0
  fi
  debug_probe="$(jq -cn '{type:"hook_timeout_warning",message:"m",fingerprint:"f",level:"warning",metadata:{hook_sequence:[],hook_timeout_debug_context:{hook_name:"master-hook.sh",hook_event:"SessionStart",budget_ms:30000,elapsed_ms:5000,remaining_ms:25000,phase_timings:[],wait_point:"parse",waiting_child_basename:"other",waiting_child_elapsed_ms:0,load_average:1.2,spawn_ms:"unavailable",process_count:"unavailable"}}}')"
  if printf '%s\n' "$debug_probe" | run_bounded 15 "$REAL_HQ_BIN" core sentry report --dry-run > "$TMP/hq-cli-debug-probe.out" 2> "$TMP/hq-cli-debug-probe.err" \
    && jq -e '.tags.timeout_debug_wait_point == "parse"' "$TMP/hq-cli-debug-probe.out" >/dev/null 2>&1; then
    HQ_CLI_DEBUG_CONTEXT_ENABLED=1
  fi
}

test_required_cli_probe_fails_closed() {
  local reject_bin="$TMP/reject-hq-bin" child_output="$TMP/required-cli-probe.out"
  mkdir -p "$reject_bin"
  cat > "$reject_bin/hq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'synthetic hq probe rejection' >&2
exit 23
EOF
  chmod +x "$reject_bin/hq"

  if C179_TEST_CASE=cli-probe-only C179_TEST_SKIP_REQUIRED_CLI_PROBE_CONTROL=1 \
    HQ_CLI_REQUIRED_IN_CI=1 PATH="$reject_bin:$ORIGINAL_PATH" \
    bash "$ROOT/core/scripts/tests/hook-timeout-watchdog-attribution.test.sh" \
      > "$child_output" 2>&1; then
    cat "$child_output" >&2
    fail "a rejected required hq CLI probe was accepted"
  fi
  grep -F -q 'HQ_CLI_REQUIRED_IN_CI=1: hq core sentry report --dry-run probe failed or returned unexpected JSON' "$child_output" \
    || { cat "$child_output" >&2; fail "required hq CLI probe failed for an unexpected reason"; }
  pass "required hq CLI probe failure is fatal"
}

test_required_cli_probe_only() {
  contract_cli_probe
  pass "hq CLI probe completed"
}

assert_cli_event_contract() {
  local event="$1" label="$2" expected_wait="$3" sequence
  if ! jq -e --arg expected_wait "$expected_wait" '
    (.metadata.hook_sequence | type == "array" and length <= 20
      and all(.[]; type == "object" and ((keys | sort) == ["event","ms","script"])
        and (.script | type == "string" and test("^[A-Za-z0-9._-]{1,128}$"))
        and (.event | type == "string" and length > 0 and length <= 48)
        and (.ms | type == "number" and . >= 0 and floor == .)))
    and .metadata.hook_timeout_debug_context.wait_point == $expected_wait
  ' <<<"$event" >/dev/null; then
    jq -c '{metadata: (.metadata | {hook_sequence, hook_timeout_debug_context, slow_child, slow_child_ms_bucket})}' <<<"$event" >&2
    fail "$label event violated the hook timeout CLI input shape"
  fi
  if [ "$HQ_CLI_CONTRACT_AVAILABLE" -eq 1 ]; then
    sequence="$(jq -c '.metadata.hook_sequence' <<<"$event")"
    if ! printf '%s\n' "$event" | run_bounded 15 "$REAL_HQ_BIN" core sentry report --dry-run > "$TMP/$label.cli-output" 2> "$TMP/$label.cli-stderr"; then
      cat "$TMP/$label.cli-stderr" "$TMP/$label.cli-output" >&2
      fail "$label event was rejected by hq core sentry report --dry-run"
    fi
    jq -e --argjson sequence "$sequence" '
      .extra.hook_sequence == $sequence
    ' "$TMP/$label.cli-output" >/dev/null || { cat "$TMP/$label.cli-output" >&2; fail "$label dry-run output lost the hook sequence array"; }
    if [ "$HQ_CLI_DEBUG_CONTEXT_ENABLED" -eq 1 ]; then
      jq -e --arg expected_wait "$expected_wait" '.tags.timeout_debug_wait_point == $expected_wait' "$TMP/$label.cli-output" >/dev/null \
        || { cat "$TMP/$label.cli-output" >&2; fail "$label dry-run output lost the debug wait-point tag"; }
    fi
  fi
  pass "$label event preserves the hq report contract"
}

watchdog_contract_event() {
  local label="$1" journal_mode="$2" root session invocation
  root="$(prepare_fixture "cli-watchdog-$label")"
  session="c179-attribution-$label"
  invocation="c179-test-$label"
  if [ "$journal_mode" = with-journal ]; then
    seed_sequence "$root" "$session"
  fi
  mkdir -p "$root/workspace/.hook-timeout-journal"
  printf 'parse\t1\t\n' > "$root/workspace/.hook-timeout-journal/$invocation.debug.tsv.active"
  run_report "$root" "$label"
  assert_cli_event_contract "$(cat "$root/event.json")" "watchdog-$label" parse
  if [ "$journal_mode" = with-journal ]; then
    jq -e '.metadata.hook_sequence | length == 5' "$root/event.json" >/dev/null || fail "$label did not include the seeded journal"
  else
    jq -e '(.metadata.hook_sequence | length == 0) and (.metadata | has("slow_child") | not)' "$root/event.json" >/dev/null \
      || fail "$label without journal invented a slow child or nonempty sequence"
  fi
}

master_contract_event() {
  local label="$1" journal_mode="$2" root session_hash journal event expected_wait with_children sentry child_timeout session_id
  root="$(prepare_fixture "cli-master-$label")"
  with_children=yes
  sentry=1
  child_timeout=1
  prepare_master_phase_fixture "$root" "$with_children"
  # A real timed child makes master-hook build a late-finish event on every
  # platform. The prior phase-delay fixture depended on whether its short
  # watchdog record survived until dispatch returned.
  printf '%s\n' '#!/usr/bin/env bash' 'cat > "${HQ_TEST_CAPTURED_INPUT:?}"' \
    'printf "first\\n" >> "${HQ_TEST_ORDER:?}"' 'sleep 3' \
    'printf "%s\\n" '\''{"hookSpecificOutput":{"additionalContext":"C179_PHASE_DELAY"}}'\''' \
    > "$root/core/hooks/SessionStart/10-slow-json.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' \
    'printf "second\\n" >> "${HQ_TEST_ORDER:?}"' 'printf "later child output"' \
    > "$root/core/hooks/SessionStart/20-later.sh"
  chmod +x "$root/core/hooks/SessionStart/10-slow-json.sh" "$root/core/hooks/SessionStart/20-later.sh"
  if [ "$journal_mode" = no-journal ]; then
    session_id=""
  else
    session_id="c179-master-phase-delay-$label"
  fi
  run_master_phase_case "$root" "$sentry" "$label" "$with_children" "$child_timeout" "$session_id"
  if [ "$journal_mode" = with-journal ]; then
    session_hash="$(sha256_fields "$session_id")"
    journal="$root/workspace/.hook-timeout-journal/$session_hash.tsv"
  fi
  event="$(sed '/^---EVENT---$/d' "$root/event.jsonl" | jq -sc '[.[] | select(.type == "hook_late_finish" or .type == "hook_timeout_exceeded")][0] // empty')"
  [ -n "$event" ] || { cat "$root/event.jsonl" >&2; fail "$label master-hook did not build a late-finish event"; }
  expected_wait="$(jq -r '.metadata.hook_timeout_debug_context.wait_point' <<<"$event")"
  assert_cli_event_contract "$event" "master-hook-$label" "$expected_wait"
  if [ "$journal_mode" = with-journal ]; then
    [ -s "$journal" ] || fail "$label master-hook fixture did not create its journal"
    jq -e '
      (.metadata.hook_sequence | length >= 1)
      and .metadata.hook_sequence[0].script == "10-slow-json.sh"
      and .metadata.slow_child == "10-slow-json.sh"
    ' <<<"$event" >/dev/null \
      || { jq -c '.metadata' <<<"$event" >&2; fail "$label master-hook journal event lost its timed child sequence"; }
  else
    jq -e '
      (.metadata.hook_sequence | length == 0)
      and .metadata.slow_child == "10-slow-json.sh"
      and (.metadata.slow_child_ms | type == "number" and . >= 0)
    ' <<<"$event" >/dev/null \
      || fail "$label master-hook without journal lost the timed child or invented a sequence"
  fi
}

test_hq_cli_event_contract() {
  contract_cli_probe
  watchdog_contract_event watchdog-no-journal no-journal
  watchdog_contract_event watchdog-journal with-journal
  master_contract_event master-no-journal no-journal
  master_contract_event master-journal with-journal
}

test_real_master_parse_phase() {
  local root_enabled root_control
  root_enabled="$(prepare_fixture master-phase-delay-enabled)"
  root_control="$(prepare_fixture master-phase-delay-control)"
  prepare_master_phase_fixture "$root_enabled"
  prepare_master_phase_fixture "$root_control"
  run_master_phase_case "$root_enabled" 1 enabled
  run_master_phase_case "$root_control" 0 control
  cmp -s "$root_enabled/out" "$root_control/out" || fail "watchdog changed composed master output"
  cmp -s "$root_enabled/err" "$root_control/err" || fail "watchdog changed master stderr"
  [ "$(cat "$root_enabled/order-at-report" 2>/dev/null || true)" = 'first' ] \
    || { cat "$root_enabled/event.jsonl" >&2 2>/dev/null || true; cat "$root_enabled/order" >&2 2>/dev/null || true; cat "$root_enabled/jq-delayed" >&2 2>/dev/null || true; cat "$root_enabled/watchdog.trigger" >&2 2>/dev/null || true; cat "$root_enabled/watchdog.status" >&2 2>/dev/null || true; fail "watchdog did not report while master was between children in parse"; }
  jq -e '
    .type == "hook_timeout_warning"
    and (.metadata | has("slow_child") | not)
    and .metadata.hook_timeout_debug_context.wait_point == "parse"
    and (.metadata | has("slow_child_ms_bucket") | not)
    and (.metadata.hook_sequence | type == "array" and length <= 20)
  ' < <(sed '/^---EVENT---$/,$d' "$root_enabled/event.jsonl") >/dev/null \
    || { cat "$root_enabled/event.jsonl" >&2; fail "real master parse-phase delay did not produce bounded phase attribution"; }
  pass "real master parse delay reports master:parse without changing composed output"
}

test_master_entry_shell_startup_phase() {
  local root event
  root="$(prepare_fixture master-entry-shell-startup)"
  prepare_master_phase_fixture "$root"
  printf '%s\n' 'unset EPOCHREALTIME' 'sleep 2' > "$root/slow-bash-env.sh"
  cat > "$root/core/hooks/SessionStart/10-slow-json.sh" <<'CHILD'
#!/usr/bin/env bash
cat > "${HQ_TEST_CAPTURED_INPUT:?}"
printf 'first\n' >> "${HQ_TEST_ORDER:?}"
sleep 2
printf '%s' '{"hookSpecificOutput":{"additionalContext":"C179_PHASE_DELAY"}}'
CHILD
  chmod +x "$root/core/hooks/SessionStart/10-slow-json.sh"
  C179_TEST_MASTER_ABSOLUTE_SECONDS=5 C179_TEST_BASH_ENV="$root/slow-bash-env.sh" \
    run_master_phase_case "$root" 1 entry-shell-startup
  unset C179_TEST_BASH_ENV C179_TEST_MASTER_ABSOLUTE_SECONDS
  event="$(sed '/^---EVENT---$/d' "$root/event.jsonl" | jq -sc '.[0]')"
  jq -e '
    .type == "hook_timeout_warning"
    and any(.metadata.hook_timeout_debug_context.phase_timings[];
      .phase == "startup" and .elapsed_ms >= 2000)
    and any(.metadata.hook_timeout_debug_context.phase_timings[];
      .phase == "external_command" and .elapsed_ms > 0)
  ' <<<"$event" >/dev/null \
    || { jq -c '.metadata.hook_timeout_debug_context.phase_timings' <<<"$event" >&2; fail "entry-shell startup and child durations were not separated"; }
  pass "entry-shell startup and child execution have separate phase durations"
}

test_master_entry_shell_startup_legacy_clock() {
  local root event
  root="$(prepare_fixture master-entry-shell-startup-legacy-clock)"
  prepare_master_phase_fixture "$root"
  cat > "$root/core/hooks/SessionStart/10-slow-json.sh" <<'CHILD'
#!/usr/bin/env bash
cat > "${HQ_TEST_CAPTURED_INPUT:?}"
printf 'first\n' >> "${HQ_TEST_ORDER:?}"
sleep 2
printf '%s' '{"hookSpecificOutput":{"additionalContext":"C179_PHASE_DELAY"}}'
CHILD
  chmod +x "$root/core/hooks/SessionStart/10-slow-json.sh"
  printf 'unset EPOCHREALTIME\n' > "$root/legacy-bash-env.sh"
  C179_TEST_MASTER_ABSOLUTE_SECONDS=5 C179_TEST_BASH_ENV="$root/legacy-bash-env.sh" \
    run_master_phase_case "$root" 1 entry-shell-startup-legacy-clock
  unset C179_TEST_BASH_ENV C179_TEST_MASTER_ABSOLUTE_SECONDS
  event="$(sed '/^---EVENT---$/d' "$root/event.jsonl" | jq -sc '.[0]')"
  jq -e '
    .type == "hook_timeout_warning"
    and (.metadata.hook_timeout_debug_context.phase_timings | type == "array")
    and any(.metadata.hook_timeout_debug_context.phase_timings[];
      .phase == "external_command" and .elapsed_ms > 0)
  ' <<<"$event" >/dev/null \
    || { jq -c '.metadata.hook_timeout_debug_context.phase_timings' <<<"$event" >&2; fail "legacy Bash lost the measured external-command phase without EPOCHREALTIME"; }
  pass "legacy Bash records measured external-command duration without EPOCHREALTIME"
}

test_legacy_active_phase_keeps_zero_duration() {
  local root
  root="$(prepare_fixture legacy-active-phase-zero-duration)"
  (
    . "$ROOT/.claude/hooks/hook-timeout-probe.sh"
    unset EPOCHREALTIME

    SECONDS=20
    local active_record
    printf -v active_record 'external_command\tseconds:%s' "$SECONDS"
    timeout 5s sleep 2
    hook_timeout_phase_timings_json "" "" "$active_record" "" "" > "$root/positive-phase.json"
    jq -e 'any(.[]; .phase == "external_command" and .elapsed_ms >= 1000)' \
      "$root/positive-phase.json" >/dev/null \
      || { jq -c . "$root/positive-phase.json" >&2; fail "legacy clock lost its positive active phase duration"; }

    unset SECONDS
    SECONDS=40
    printf -v active_record 'external_command\tseconds:%s' "$SECONDS"
    hook_timeout_phase_timings_json "" "" "$active_record" "" "" > "$root/zero-phase.json"
    jq -e '([.[] | select(.phase == "external_command")]) as $phases | ((($phases | length) == 1) and ($phases[0].elapsed_ms == 0))' \
      "$root/zero-phase.json" >/dev/null \
      || { jq -c . "$root/zero-phase.json" >&2; fail "legacy clock did not emit exactly one zero-duration active phase"; }
  ) || fail "legacy active phase timing assertions failed"
  pass "legacy active phases retain positive durations and keep exactly one zero-duration sample"
}

test_monitor_readiness_phase() {
  local root phase_dir monitor_file monitor_active
  root="$(prepare_fixture monitor-readiness-phase)"
  phase_dir="$root/workspace/.hook-timeout-journal"
  monitor_file="$phase_dir/monitor.tsv"
  monitor_active="$monitor_file.active"
  mkdir -p "$phase_dir" "$root/core/scripts" "$root/workspace/monitors/sessions/claude-phase-tags-monitor/dropbox"
  cp "$ROOT/core/scripts/hook-lib.sh" "$root/core/scripts/hook-lib.sh"
  cp "$ROOT/.claude/hooks/hq-monitor-session-hook.sh" "$root/.claude/hooks/hq-monitor-session-hook.sh"
  cp "$ROOT/.claude/hooks/hq-monitor-hook-lib.sh" "$root/.claude/hooks/hq-monitor-hook-lib.sh"
  cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$root/.claude/hooks/hook-timeout-probe.sh"
  printf '{}\n' > "$root/workspace/monitors/sessions/claude-phase-tags-monitor/dropbox/inbox.jsonl"
  : > "$monitor_file"
  : > "$monitor_active"
  cat > "$root/bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  printf '  monitor\n'
  exit 0
fi
if [ "${1:-}" = "monitor" ] && [ "${2:-}" = "drain" ]; then
  cat >/dev/null
  exit 0
fi
exit 91
HQ
  chmod +x "$root/bin/hq"
  if ! run_bounded 30 env \
    "CLAUDE_PROJECT_DIR=$root" \
    "PATH=$root/bin:$ORIGINAL_PATH" \
    "HQ_HOOK_TIMEOUT_CHILD_PHASE_FILE=$monitor_file" \
    "HQ_HOOK_TIMEOUT_CHILD_ACTIVE_PHASE_FILE=$monitor_active" \
    bash "$root/.claude/hooks/hq-monitor-session-hook.sh" drain PreToolUse \
      <<<'{"session_id":"phase-tags-monitor"}' > "$root/monitor.out" 2> "$root/monitor.err"; then
    cat "$root/monitor.err" >&2
    fail "monitor readiness fixture did not run"
  fi
  grep -Eq '^probe[[:space:]]+[0-9]+$' "$monitor_file" \
    || fail "monitor hook did not record its readiness check"
  pass "monitor readiness phase is recorded"
}

test_journal_missing_probe_fails_soft() {
  local root journal_payload rc
  root="$(prepare_fixture journal-missing-probe)"
  mkdir -p "$root/core/scripts" "$root/workspace/threads/journal/2026-09-30"
  cp "$ROOT/.claude/hooks/journal-due.sh" "$root/.claude/hooks/journal-due.sh"
  cp "$ROOT/core/scripts/hook-lib.sh" "$root/core/scripts/hook-lib.sh"
  rm -f "$root/.claude/hooks/hook-timeout-probe.sh"

  cat > "$root/core/scripts/session-journal.sh" <<'JOURNAL'
#!/usr/bin/env bash
case "${1:-}" in
  dir-path) printf '%s\n' "${HQ_TEST_JOURNAL_DIR:?}" ;;
  *) exit 0 ;;
esac
JOURNAL
  chmod +x "$root/core/scripts/session-journal.sh"
  journal_payload='{"tool_name":"Read","session_id":"missing-probe","tool_response":{"exit_code":0}}'
  if printf '%s' "$journal_payload" | env \
    "HQ_ROOT=$root" "CLAUDE_PROJECT_DIR=$root" \
    "HQ_TEST_JOURNAL_DIR=$root/workspace/threads/journal/2026-09-30" \
    bash "$root/.claude/hooks/journal-due.sh" >"$root/journal.out" 2>"$root/journal.err"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" = 0 ] && [ ! -s "$root/journal.out" ] && [ ! -s "$root/journal.err" ] \
    || { cat "$root/journal.err" >&2; fail "journal-due with missing probe expected exit 0 and empty output (rc=$rc)"; }
  pass "journal-due remains silent when hook-timeout-probe.sh is absent"
}

test_monitor_missing_probe_fails_soft() {
  local root monitor_payload rc
  root="$(prepare_fixture monitor-missing-probe)"
  mkdir -p "$root/core/scripts" "$root/workspace/monitors/sessions/claude-missing-probe/dropbox"
  cp "$ROOT/.claude/hooks/hq-monitor-session-hook.sh" "$root/.claude/hooks/hq-monitor-session-hook.sh"
  cp "$ROOT/.claude/hooks/hq-monitor-hook-lib.sh" "$root/.claude/hooks/hq-monitor-hook-lib.sh"
  cp "$ROOT/core/scripts/hook-lib.sh" "$root/core/scripts/hook-lib.sh"
  rm -f "$root/.claude/hooks/hook-timeout-probe.sh"
  cat > "$root/bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  printf '  monitor\n'
  exit 0
fi
if [ "${1:-}" = "monitor" ] && [ "${2:-}" = "drain" ]; then
  cat >/dev/null
  exit 0
fi
exit 91
HQ
  chmod +x "$root/bin/hq"
  monitor_payload='{"session_id":"missing-probe"}'
  printf '%s\n' "$monitor_payload" \
    > "$root/workspace/monitors/sessions/claude-missing-probe/dropbox/inbox.jsonl"
  if printf '%s' "$monitor_payload" | env \
    "HQ_ROOT=$root" "CLAUDE_PROJECT_DIR=$root" "PATH=$root/bin:$ORIGINAL_PATH" \
    HQ_CHECKPOINT_RUNTIME=claude \
    bash "$root/.claude/hooks/hq-monitor-session-hook.sh" drain PreToolUse \
      >"$root/monitor.out" 2>"$root/monitor.err"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" = 0 ] && [ ! -s "$root/monitor.out" ] && [ ! -s "$root/monitor.err" ] \
    || { cat "$root/monitor.err" >&2; fail "monitor hook with missing probe expected exit 0 and empty output (rc=$rc)"; }
  pass "monitor hook remains silent when hook-timeout-probe.sh is absent"
}

test_missing_probe_fails_soft() {
  test_journal_missing_probe_fails_soft
  test_monitor_missing_probe_fails_soft
}

test_child_phase_tags() {
  local root phase_dir journal_file monitor_file monitor_active child_file child_active_file now_ms child_active_record phase_timings debug_context report
  root="$(prepare_fixture child-phase-tags)"
  phase_dir="$root/workspace/.hook-timeout-journal"
  mkdir -p "$phase_dir" "$root/core/scripts" "$root/workspace/threads/journal" \
    "$root/workspace/monitors/sessions/claude-phase-tags-monitor/dropbox"
  cp "$ROOT/.claude/hooks/journal-due.sh" "$root/.claude/hooks/journal-due.sh"
  cp "$ROOT/.claude/hooks/hq-monitor-session-hook.sh" "$root/.claude/hooks/hq-monitor-session-hook.sh"
  cp "$ROOT/.claude/hooks/hq-monitor-hook-lib.sh" "$root/.claude/hooks/hq-monitor-hook-lib.sh"
  cp "$ROOT/core/scripts/hook-lib.sh" "$root/core/scripts/hook-lib.sh"
  cp "$ROOT/core/scripts/session-journal.sh" "$root/core/scripts/session-journal.sh"

  journal_file="$phase_dir/journal-due.tsv"
  : > "$journal_file"
  : > "$journal_file.active"
  if ! run_bounded 30 env \
    "CLAUDE_PROJECT_DIR=$root" \
    "HQ_HOOK_TIMEOUT_CHILD_PHASE_FILE=$journal_file" \
    "HQ_HOOK_TIMEOUT_CHILD_ACTIVE_PHASE_FILE=$journal_file.active" \
    bash "$root/.claude/hooks/journal-due.sh" \
      <<<'{"tool_name":"Read","tool_response":{"exit_code":0},"session_id":"phase-tags-journal"}' \
      > "$root/journal.out" 2> "$root/journal.err"; then
    cat "$root/journal.err" >&2
    fail "journal-due phase fixture did not run"
  fi
  grep -Eq '^parse[[:space:]]+[0-9]+$' "$journal_file" \
    || fail "journal-due did not record its JSON/helper parse group"
  grep -Eq '^child_wait[[:space:]]+[0-9]+$' "$journal_file" \
    || fail "journal-due did not record its journal-helper group"

  monitor_file="$phase_dir/monitor.tsv"
  monitor_active="$monitor_file.active"
  printf '{}\n' > "$root/workspace/monitors/sessions/claude-phase-tags-monitor/dropbox/inbox.jsonl"
  : > "$monitor_file"
  : > "$monitor_active"
  cat > "$root/bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  printf '  monitor\n'
  exit 0
fi
if [ "${1:-}" = "monitor" ] && [ "${2:-}" = "drain" ]; then
  cat >/dev/null
  exit 0
fi
exit 91
HQ
  chmod +x "$root/bin/hq"
  if ! run_bounded 30 env \
    "CLAUDE_PROJECT_DIR=$root" \
    "PATH=$root/bin:$ORIGINAL_PATH" \
    "HQ_HOOK_TIMEOUT_CHILD_PHASE_FILE=$monitor_file" \
    "HQ_HOOK_TIMEOUT_CHILD_ACTIVE_PHASE_FILE=$monitor_active" \
    bash "$root/.claude/hooks/hq-monitor-session-hook.sh" drain PreToolUse \
      <<<'{"session_id":"phase-tags-monitor"}' > "$root/monitor.out" 2> "$root/monitor.err"; then
    cat "$root/monitor.err" >&2
    fail "monitor phase fixture did not run"
  fi
  grep -Eq '^probe[[:space:]]+[0-9]+$' "$monitor_file" \
    || fail "monitor hook did not record its readiness check"
  grep -Eq '^child_wait[[:space:]]+[0-9]{1,16}$' "$monitor_active" \
    || fail "monitor hook did not leave the drain phase active through exec"

  grep -Fq 'master_debug_phase_buffer_record startup' "$ROOT/.claude/hooks/master-hook.sh" \
    || fail "master-hook omitted its entry-shell startup measurement"
  grep -Fq 'hook_timeout_child_phase_start parse' "$ROOT/.claude/hooks/journal-due.sh" \
    || fail "journal-due omitted its JSON helper phase"
  grep -Fq 'hook_timeout_child_phase_start child_wait' "$ROOT/.claude/hooks/journal-due.sh" \
    || fail "journal-due omitted its helper-call phase"
  grep -Fq 'hook_timeout_child_phase_start probe' "$ROOT/.claude/hooks/hq-monitor-session-hook.sh" \
    || fail "monitor hook omitted its readiness phase"
  grep -Fq 'hook_timeout_child_phase_start child_wait' "$ROOT/.claude/hooks/hq-monitor-session-hook.sh" \
    || fail "monitor hook omitted its drain phase"

  child_file="$phase_dir/c179-test-child-phase-tags.debug.tsv.child"
  child_active_file="$child_file.active"
  now_ms="$(bash -c '. "$1"; hook_timeout_now_ms' _ "$ROOT/.claude/hooks/hook-timeout-probe.sh")"
  [[ "$now_ms" =~ ^[0-9]{1,16}$ ]] || fail "test clock did not return milliseconds"
  printf 'startup\t12000\nexternal_command\t7000\nparse\t1500\nprobe\t3000\n' > "$child_file"
  printf 'child_wait\t%s\n' "$((now_ms - 15000))" > "$child_active_file"

  (
    . "$ROOT/.claude/hooks/hook-timeout-probe.sh"
    phase_timings="$(hook_timeout_phase_timings_json "" "" "" "$child_file" "$(cat "$child_active_file")")"
    printf '%s' "$phase_timings" > "$root/phase-timings.json"
    debug_context="$(hook_timeout_debug_context_json \
      journal-due.sh PostToolUse 30000 12000 18000 "$phase_timings" parse other 0 0.1 unavailable unavailable)"
    printf '%s' "$debug_context" > "$root/debug-context.json"
  ) || fail "child phase timing aggregation failed"
  jq -e '
    any(.[]; .phase == "startup" and .elapsed_ms == 12000)
    and any(.[]; .phase == "external_command" and .elapsed_ms == 7000)
    and any(.[]; .phase == "parse" and .elapsed_ms == 1500)
    and any(.[]; .phase == "probe" and .elapsed_ms == 3000)
    and any(.[]; .phase == "child_wait" and .elapsed_ms >= 15000)
  ' "$root/phase-timings.json" >/dev/null \
    || { jq -c . "$root/phase-timings.json" >&2; fail "child phase durations were not included in the attribution context"; }

  # Model the Bash 3.2 master and its separately launched watchdog sharing the
  # SECONDS value explicitly passed at process start.
  unset EPOCHREALTIME
  SECONDS=20
  export SECONDS
  . "$ROOT/.claude/hooks/hook-timeout-probe.sh"
  MASTER_DEBUG_ACTIVE_PHASE_FILE="$root/master-active.tsv"
  MASTER_DEBUG_PHASE_BUFFER=()
  master_debug_phase_start policy_load
  grep -Eq '^policy_load[[:space:]]seconds:[0-9]+[[:space:]]' "$root/master-active.tsv" \
    || fail "legacy Bash parent marker did not use the shared SECONDS clock"
  timeout 5s sleep 2
  child_active_record="$(cat "$child_active_file")"
  phase_timings="$(SECONDS="$SECONDS" bash -c '
    . "$1"
    hook_timeout_phase_timings_json "" "$2" "__read_active__" "$3" "$4"
  ' _ "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$root/master-active.tsv" "$child_file" "$child_active_record")" \
    || fail "active phase fallback failed when child timing inputs were supplied"
  printf '%s' "$phase_timings" > "$root/active-phase-timings.json"
  jq -e '
    any(.[]; .phase == "policy_load" and .elapsed_ms >= 2000)
    and any(.[]; .phase == "child_wait" and .elapsed_ms >= 15000)
  ' \
    "$root/active-phase-timings.json" >/dev/null \
    || { jq -c . "$root/active-phase-timings.json" >&2; fail "active parent or child phase was lost when child timing inputs were supplied"; }

  (
    . "$ROOT/.claude/hooks/hook-timeout-probe.sh"
    phase_timings="$(hook_timeout_phase_timings_json "" "" "" "$child_file" "")"
    printf '%s' "$phase_timings" > "$root/empty-child-snapshot-timings.json"
  ) || fail "explicitly empty child phase snapshot was not accepted"
  jq -e 'all(.[]; .phase != "child_wait")' \
    "$root/empty-child-snapshot-timings.json" >/dev/null \
    || { jq -c . "$root/empty-child-snapshot-timings.json" >&2; fail "explicitly empty child phase snapshot was replaced by the later live marker"; }
  echo "ok: explicitly empty child phase snapshots are not replaced by a later live marker"

  (
    . "$ROOT/.claude/hooks/hook-timeout-probe.sh"
    phase_timings="$(hook_timeout_phase_timings_json "" "$root/master-active.tsv" "" "$child_file" "")"
    printf '%s' "$phase_timings" > "$root/empty-parent-snapshot-timings.json"
  ) || fail "explicitly empty parent phase snapshot was not accepted"
  jq -e 'all(.[]; .phase != "policy_load" or .elapsed_ms == 0)' \
    "$root/empty-parent-snapshot-timings.json" >/dev/null \
    || { jq -c . "$root/empty-parent-snapshot-timings.json" >&2; fail "explicitly empty parent phase snapshot was replaced by the later live marker"; }
  echo "ok: explicitly empty parent phase snapshots are not replaced by a later live marker"

  contract_cli_probe
  if [ "$HQ_CLI_DEBUG_CONTEXT_ENABLED" -eq 1 ]; then
    report="$(jq -cn --argjson context "$(cat "$root/debug-context.json")" \
      '{type:"hook_timeout_warning",message:"m",fingerprint:"f",level:"warning",metadata:{hook_sequence:[],hook_timeout_debug_context:$context}}')"
    printf '%s\n' "$report" | run_bounded 15 "$REAL_HQ_BIN" core sentry report --dry-run \
      > "$root/cli-event.json" 2> "$root/cli-event.err" \
      || { cat "$root/cli-event.err" "$root/cli-event.json" >&2; fail "phase tags were rejected by hq sentry report"; }
    jq -e '
      .tags.timeout_debug_phase_startup_bucket == "10-20s"
      and .tags.timeout_debug_phase_external_command_bucket == "5-10s"
      and .tags.timeout_debug_phase_parse_bucket == "<5s"
      and .tags.timeout_debug_phase_probe_bucket == "<5s"
      and .tags.timeout_debug_phase_child_wait_bucket == "10-20s"
    ' "$root/cli-event.json" >/dev/null \
      || { jq -c '.tags' "$root/cli-event.json" >&2; fail "phase duration buckets were not emitted as Sentry tags"; }
  fi
  pass "startup, child, JSON/helper, readiness, and drain durations reach bucketed attribution tags"
}

case "$CASE" in
  windows-slow-start) test_windows_slow_start_budget ;;
  slow-child) test_slow_child_tag ;;
  session-start-mesh-debug-name) test_session_start_mesh_hook_debug_name ;;
  master-phase) test_master_phase_tag ;;
  hook-sequence) test_hook_sequence_array ;;
  master-phase-delay) test_real_master_parse_phase ;;
  master-entry-shell-startup) test_master_entry_shell_startup_phase; test_master_entry_shell_startup_legacy_clock ;;
  child-phase-tags) test_child_phase_tags ;;
  monitor-readiness-phase) test_monitor_readiness_phase ;;
  legacy-zero-phase) test_legacy_active_phase_keeps_zero_duration ;;
  journal-missing-probe) test_journal_missing_probe_fails_soft ;;
  monitor-missing-probe) test_monitor_missing_probe_fails_soft ;;
  missing-probe-fallback) test_missing_probe_fails_soft ;;
  master-late-active-phase) test_master_late_active_phase ;;
  master-dispatch-startup-elapsed) test_master_dispatch_startup_elapsed ;;
  watchdog-trigger-phase-snapshot) test_watchdog_trigger_phase_snapshot ;;
  read-eof-errexit) test_eof_read_under_errexit ;;
  journal-filter) test_journal_sequence_filter ;;
  cli-contract)
    if [ "${C179_TEST_SKIP_REQUIRED_CLI_PROBE_CONTROL:-0}" != "1" ]; then
      test_required_cli_probe_fails_closed
    fi
    test_hq_cli_event_contract
    ;;
  cli-probe-only)
    test_required_cli_probe_only
    ;;
  cli-probe-control)
    test_required_cli_probe_fails_closed
    ;;
  all)
    test_slow_child_tag
    test_session_start_mesh_hook_debug_name
    test_master_phase_tag
    test_hook_sequence_array
    test_real_master_parse_phase
    test_master_entry_shell_startup_phase
    test_master_entry_shell_startup_legacy_clock
    test_child_phase_tags
    test_monitor_readiness_phase
    test_legacy_active_phase_keeps_zero_duration
    test_missing_probe_fails_soft
    test_master_late_active_phase
    test_master_dispatch_startup_elapsed
    test_watchdog_trigger_phase_snapshot
    test_eof_read_under_errexit
    test_journal_sequence_filter
    if [ "${C179_TEST_SKIP_REQUIRED_CLI_PROBE_CONTROL:-0}" != "1" ]; then
      test_required_cli_probe_fails_closed
    fi
    test_hq_cli_event_contract
    ;;
  *) fail "unknown C179_TEST_CASE: $CASE" ;;
esac
