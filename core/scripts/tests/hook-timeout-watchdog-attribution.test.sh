#!/usr/bin/env bash
# HQ_CLI_REQUIRED_IN_CI: the real sentry-report probes below must run in CI.
set -euo pipefail

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

run_report() {
  local root="$1" label="$2" session="c179-attribution-$2" invocation="c179-test-$2"
  local hook_path="$root/.claude/hooks/master-hook.sh" fixture_bin
  fixture_bin="$(fixture_path "$root/bin")"
  printf 'master-dispatch\t%s\tabsolute\n' "$hook_path" > "$root/trigger.tsv"
  run_fixture_bounded 10 \
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
  && [ "${1:-}" = "-r" ] && [ "${2:-}" = "--arg" ] \
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
    'BASH_ENV=' \
    'HQ_HARNESS=codex' \
    "HOME=$root/home" \
    'HQ_DISABLED_HOOKS=' \
    "HQ_HOOK_TIMEOUT_SENTRY=$sentry" \
    "HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE=$root/watchdog.trigger" \
    "HQ_HOOK_TIMEOUT_SENTRY_TEST_STATUS_FILE=$root/watchdog.status" \
    'HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=2' \
    'HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=20' \
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
  if [ "$with_children" = yes ]; then
    cmp -s "$root/expected-input" "$root/captured-input" \
      || fail "$label SessionStart stdin differed from command-substitution semantics"
    [ "$(cat "$root/order")" = $'first\nsecond' ] || fail "$label did not dispatch both children in order"
  else
    [ ! -s "$root/order" ] || fail "$label unexpectedly dispatched a child"
  fi
  [ ! -s "$root/err" ] || fail "$label master hook changed stderr"
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
    bash "$root/.claude/hooks/master-hook.sh" SessionStart \
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
  ) || fail "master late report fixture failed"
  sed '/^---EVENT---$/,$d' "$root/event.jsonl" > "$root/event.json"
  jq -e '
    .type == "hook_late_finish"
    and (.metadata | has("slow_child") | not)
    and .metadata.hook_timeout_debug_context.wait_point == "external_command"
  ' "$root/event.json" >/dev/null || {
    jq -c '.metadata | {slow_child, hook_timeout_debug_context}' "$root/event.json" >&2
    fail "master late report lost the active external_command phase"
  }
  pass "master late report with no slow child retains the active phase"
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

case "$CASE" in
  slow-child) test_slow_child_tag ;;
  master-phase) test_master_phase_tag ;;
  hook-sequence) test_hook_sequence_array ;;
  master-phase-delay) test_real_master_parse_phase ;;
  master-late-active-phase) test_master_late_active_phase ;;
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
    test_master_phase_tag
    test_hook_sequence_array
    test_real_master_parse_phase
    test_master_late_active_phase
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
