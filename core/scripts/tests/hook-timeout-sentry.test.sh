#!/usr/bin/env bash
# Behavioral coverage for the timeout-warning watchdog. All Sentry collaborators
# are fake: the contract is the exact stdin JSON sent to `hq core sentry report`.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
PORTABLE_LIB="$ROOT/core/scripts/lib/portable.sh"
GATE_SRC="$ROOT/.claude/hooks/hook-gate.sh"
MASTER_SRC="$ROOT/.claude/hooks/master-hook.sh"
WATCHDOG_SRC="$ROOT/.claude/hooks/hook-timeout-watchdog.sh"
PROBE_SRC="$ROOT/.claude/hooks/hook-timeout-probe.sh"
SETTINGS_SRC="$ROOT/.claude/settings.json"
REGISTRY_SRC="$ROOT/.claude/hooks/hook-registry.json"
CODEX_CONFIG_SRC="$ROOT/.codex/config.toml"
GROK_BRIDGE_SRC="$ROOT/.grok/hooks/hq-grok-user-bridge.json"
SYSTEM_JQ="$(command -v jq)"
SYSTEM_NODE="$(command -v node 2>/dev/null || true)"
SYSTEM_QMD="$(command -v qmd 2>/dev/null || true)"

# shellcheck source=core/scripts/lib/portable.sh
. "$PORTABLE_LIB"

# master-hook.sh keeps the watchdog off by default in Git Bash because it is
# costly on Windows. This suite exercises watchdog behavior deliberately; the
# explicit disabled-path fixtures below still override this with 0.
export HQ_HOOK_TIMEOUT_SENTRY=1
export HQ_TEST_SYSTEM_JQ="$SYSTEM_JQ"
export HQ_TEST_SYSTEM_NODE="$SYSTEM_NODE"
export HQ_TEST_SYSTEM_QMD="$SYSTEM_QMD"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d)"
export HQ_TEST_HQ_UPDATE_CHECK="$TMP/hq-update-check"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
timeout_version=""
timeout_bin="$(command -v timeout 2>/dev/null || true)"
if command -v timeout >/dev/null 2>&1; then
  timeout_version="$("$timeout_bin" --version 2>/dev/null || true)"
fi
case "$timeout_version" in
  *"GNU coreutils"*) ;;
  *)
    # Git Bash may have GNU timeout.exe installed even when Windows' native
    # timeout.exe shadows it earlier on PATH.
    for candidate in /usr/bin/timeout.exe /usr/bin/timeout /bin/timeout.exe /bin/timeout; do
      [ -x "$candidate" ] || continue
      candidate_version="$("$candidate" --version 2>/dev/null || true)"
      case "$candidate_version" in
        *"GNU coreutils"*) timeout_bin="$candidate"; timeout_version="$candidate_version"; break ;;
      esac
    done
    ;;
esac
case "$timeout_version" in
  *"GNU coreutils"*)
    if [ "$timeout_bin" != "$(command -v timeout 2>/dev/null || true)" ]; then
      export HQ_TEST_GNU_TIMEOUT_BIN="$timeout_bin"
      cat > "$TMP/bin/timeout" <<'EOF'
#!/usr/bin/env bash
exec "${HQ_TEST_GNU_TIMEOUT_BIN:?}" "$@"
EOF
      chmod +x "$TMP/bin/timeout"
      PATH="$TMP/bin:$PATH"
      export PATH
    fi
    ;;
  *)
    command -v perl >/dev/null 2>&1 || fail 'neither GNU timeout nor Perl is available for bounded hook tests'
    cat > "$TMP/bin/timeout" <<'EOF'
#!/usr/bin/env bash
seconds="${1%s}"
shift
exec perl -e 'alarm shift; exec @ARGV or exit 127' "$seconds" "$@"
EOF
    chmod +x "$TMP/bin/timeout"
    PATH="$TMP/bin:$PATH"
    export PATH
    ;;
esac

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
  [ ! -f "$PROBE_SRC" ] || cp "$PROBE_SRC" "$root/.claude/hooks/hook-timeout-probe.sh"
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
printf '%s\n' "${HQ_NO_UPDATE_CHECK:-unset}" >> "${HQ_TEST_HQ_UPDATE_CHECK:?}"
printf '%s\n' "$*" >> "${HQ_TEST_HQ_ARGS:?}"
cat >> "${HQ_TEST_HQ_STDIN:?}"
printf '\n---EVENT---\n' >> "${HQ_TEST_HQ_STDIN:?}"
printf 'reported\n' >> "${HQ_TEST_HQ_ACK:?}"
if [ "${HQ_TEST_HQ_FAIL:-0}" = "1" ]; then
  exit 17
fi
EOF
  chmod +x "$root/bin/hq"
  # Keep hq_augment_path on its fast path so fixture hq remains the reporter.
  # Delegate any actual node/qmd call to the host tool rather than changing its
  # behavior; fail clearly if the host does not provide that optional tool.
  cat > "$root/bin/node" <<'EOF'
#!/usr/bin/env bash
if [ -n "${HQ_TEST_SYSTEM_NODE:-}" ]; then
  exec "$HQ_TEST_SYSTEM_NODE" "$@"
fi
printf 'node unavailable in isolated hook fixture\n' >&2
exit 127
EOF
  cat > "$root/bin/qmd" <<'EOF'
#!/usr/bin/env bash
if [ -n "${HQ_TEST_SYSTEM_QMD:-}" ]; then
  exec "$HQ_TEST_SYSTEM_QMD" "$@"
fi
printf 'qmd unavailable in isolated hook fixture\n' >&2
exit 127
EOF
  chmod +x "$root/bin/node" "$root/bin/qmd"
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

payload_for_event_with_cwd() {
  local event="$1" session="$2" cwd="$3"
  jq -cn --arg event "$event" --arg session "$session" --arg cwd "$cwd" '{
    hook_event_name: $event,
    tool_name: "Bash",
    session_id: $session,
    cwd: $cwd,
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
    BASH_ENV= \
    HQ_TEST_HQ_ARGS="$root/hq.args" \
    HQ_TEST_HQ_STDIN="$root/hq.stdin" \
    HQ_TEST_HQ_ACK="$root/hq.ack" \
    HQ_HOOK_TIMEOUT_SENTRY_LEAD_SECONDS=2 \
    HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$root/watchdog.trigger" \
    HQ_HOOK_TIMEOUT_SENTRY_TEST_ARMED_FILE="$root/watchdog.armed" \
    HQ_HOOK_TIMEOUT_SENTRY_TEST_STATUS_FILE="$root/watchdog.status" \
    "$@" \
    timeout 15s bash "$root/.claude/hooks/hook-gate.sh" detect-secrets "$root/.claude/hooks/detect-secrets.sh" \
      >"$out" 2>"$err" <<<"$(payload "$session")"
}

run_watchdog_for_fingerprint() {
  local root="$1" hook_path="$2" event="$3" label="$4" root_arg="${5:-$1}"
  local report="$root/$label.hq.stdin" acknowledgement="$root/$label.hq.ack"

  printf '%s\t%s\t%s\n' master-child "$hook_path" relative > "$root/watchdog.trigger"
  env \
    PATH="$root/bin:$PATH" \
    HQ_TEST_HQ_ARGS="$root/$label.hq.args" \
    HQ_TEST_HQ_STDIN="$report" \
    HQ_TEST_HQ_ACK="$acknowledgement" \
    HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2 \
    HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$root/watchdog.trigger" \
    timeout 15s bash "$root/.claude/hooks/hook-timeout-watchdog.sh" \
      --root "$root_arg" --source master-child --hook-path "$hook_path" \
      --event "$event" --threshold relative --started-at 0 \
      >"$root/$label.out" 2>"$root/$label.err" <<<"$(payload_for_event "$event" "$label-session")"
  [ "$(grep -c '^---EVENT---$' "$report")" = "1" ] \
    || fail "$label watchdog did not report exactly one event"
  [ ! -s "$root/$label.err" ] || fail "$label watchdog wrote to stderr"
}

fingerprint_from_report() {
  jq -r '.fingerprint' < <(sed '/^---EVENT---$/,$d' "$1")
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

if ps -eww -o args= >/dev/null 2>&1; then
  WATCHDOG_PROCESS_PROBE_MODE="ps -eww -o args="
else
  # Git Bash's MSYS ps does not implement GNU `-o args=`.
  WATCHDOG_PROCESS_PROBE_MODE="ps -ef"
fi

watchdog_process_listing() {
  case "$WATCHDOG_PROCESS_PROBE_MODE" in
    'ps -eww -o args=')
      # shellcheck disable=SC2009 # -ww keeps the exact watcher path visible.
      ps -eww -o args=
      ;;
    'ps -ef')
      # shellcheck disable=SC2009 # MSYS fallback, verified by the positive control below.
      ps -ef
      ;;
  esac
}

watchdog_process_visible() {
  local marker="$1" listing
  listing="$(watchdog_process_listing)" || return 1
  case "$listing" in *"$marker"*) return 0 ;; esac
  return 1
}

watchdog_running() {
  local root="$1"
  watchdog_process_visible "$root/.claude/hooks/hook-timeout-watchdog.sh"
}

assert_watchdog_process_probe() {
  local probe_root="$TMP/process-probe"
  local probe_script="$probe_root/.claude/hooks/hook-timeout-watchdog-probe.sh"
  local probe_pid
  mkdir -p "${probe_script%/*}"
  cat > "$probe_script" <<'EOF'
#!/usr/bin/env bash
while :; do sleep 0.1; done
EOF
  chmod +x "$probe_script"
  bash "$probe_script" &
  probe_pid=$!

  for _ in $(seq 1 100); do
    if watchdog_process_visible "$probe_script"; then
      kill "$probe_pid" >/dev/null 2>&1 || true
      wait "$probe_pid" 2>/dev/null || true
      pass "process probe sees a live watchdog-shaped bash command ($WATCHDOG_PROCESS_PROBE_MODE)"
      return 0
    fi
    sleep 0.02
  done

  kill "$probe_pid" >/dev/null 2>&1 || true
  wait "$probe_pid" 2>/dev/null || true
  fail "watchdog process probe is blind on this platform: $WATCHDOG_PROCESS_PROBE_MODE could not see live $probe_script"
}

echo "[probe] process table can observe a live watchdog-shaped command"
assert_watchdog_process_probe

if [ "${HQ_HOOK_TIMEOUT_SENTRY_SKIP_PLATFORM_PROBE_TEST:-0}" != "1" ]; then
echo "[probe] load and Windows spawn probes cover all supported platforms"
probe_failures=0
probe_assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    probe_failures=$((probe_failures + 1))
    printf 'FAIL: %s expected <%s>, got <%s>\n' "$label" "$expected" "$actual" >&2
  fi
}
if [ -f "$PROBE_SRC" ]; then
  . "$PROBE_SRC"
  probe_root="$TMP/platform-probe"
  mkdir -p "$probe_root/bin"
  printf '1.25 0.75 3.50 1/20 100\n' > "$probe_root/linux-loadavg"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "{ 2.75 1.50 0.40 }\\n"' \
    > "$probe_root/bin/sysctl"
  chmod +x "$probe_root/bin/sysctl"
  probe_assert_eq 'Linux load average reads /proc/loadavg' '1.25' \
    "$(hook_timeout_load_average Linux "$probe_root/linux-loadavg" "$probe_root/bin/sysctl")"
  probe_assert_eq 'Darwin load average parses sysctl braces' '2.75' \
    "$(hook_timeout_load_average Darwin "$probe_root/missing-loadavg" "$probe_root/bin/sysctl")"
  probe_assert_eq 'Windows has an explicit no-load-average value' 'unavailable' \
    "$(hook_timeout_load_average MINGW64_NT-10.0 "$probe_root/missing-loadavg" "$probe_root/bin/sysctl")"
  probe_assert_eq 'Linux platform name is bounded' 'linux' \
    "$(hook_timeout_os_name Linux)"
  probe_assert_eq 'Darwin platform name is bounded' 'macos' \
    "$(hook_timeout_os_name Darwin)"
  probe_assert_eq 'Git Bash platform name is bounded' 'windows' \
    "$(hook_timeout_os_name MINGW64_NT-10.0)"
  if hook_timeout_has_gnu_timeout; then
    printf '%s\n' '#!/usr/bin/env bash' 'trap "" TERM' 'exec sleep 4' \
      > "$probe_root/bin/term-resistant"
    chmod +x "$probe_root/bin/term-resistant"
    bounded_probe_rc=0
    hook_timeout_run_bounded 1 "$probe_root/bin/term-resistant" 2>/dev/null || bounded_probe_rc=$?
    probe_assert_eq 'GNU bounded probe kills a TERM-resistant command' 137 "$bounded_probe_rc"
  fi
  printf '%s\n' '#!/bin/sh' \
    'printf x >> "${HQ_TEST_SPAWN_CALLS:?}"' \
    > "$probe_root/bin/fake-bash"
  chmod +x "$probe_root/bin/fake-bash"
  export HQ_TEST_SPAWN_CALLS="$probe_root/spawn-calls"
  export HQ_TEST_POWERSHELL_CALLS="$probe_root/powershell-calls"
  cat > "$probe_root/bin/powershell-fixture" <<'EOF'
#!/usr/bin/env bash
[ -n "${HQ_HOOK_TIMEOUT_SPAWN_SHELL:-}" ] || exit 127
printf x >> "${HQ_TEST_POWERSHELL_CALLS:?}"
printf '17'
EOF
  chmod +x "$probe_root/bin/powershell-fixture"
  spawn_cache="$probe_root/session.spawn-ms"
  spawn_first="$(hook_timeout_spawn_ms "$spawn_cache" "$probe_root/bin/fake-bash" MINGW64_NT-10.0 "$probe_root/bin/powershell-fixture")"
  spawn_second="$(hook_timeout_spawn_ms "$spawn_cache" "$probe_root/bin/fake-bash" MINGW64_NT-10.0 "$probe_root/bin/powershell-fixture")"
  case "$spawn_first" in ''|*[!0-9]*) probe_failures=$((probe_failures + 1)); echo 'FAIL: Windows spawn probe did not return milliseconds' >&2 ;; esac
  probe_assert_eq 'Windows spawn probe cache is stable' "$spawn_first" "$spawn_second"
  probe_assert_eq 'Windows spawn probe runs once per session' 1 "$(wc -c < "$HQ_TEST_POWERSHELL_CALLS" | tr -d ' ')"
  interrupted_spawn_cache="$probe_root/session.spawn-interrupted-ms"
  interrupted_spawn_started="$probe_root/interrupted-spawn-started"
  interrupted_spawn_release="$probe_root/interrupted-spawn-release"
  export HQ_TEST_INTERRUPTED_SPAWN_STARTED="$interrupted_spawn_started"
  export HQ_TEST_INTERRUPTED_SPAWN_RELEASE="$interrupted_spawn_release"
  (
    hook_timeout_run_bounded() {
      : > "$HQ_TEST_INTERRUPTED_SPAWN_STARTED"
      while [ ! -e "$HQ_TEST_INTERRUPTED_SPAWN_RELEASE" ]; do sleep 0.01; done
      return 0
    }
    hook_timeout_spawn_ms "$interrupted_spawn_cache" "$probe_root/bin/fake-bash" Linux
  ) > "$probe_root/interrupted-spawn.out" 2>/dev/null &
  interrupted_spawn_pid=$!
  for _ in {1..200}; do
    [ -e "$interrupted_spawn_started" ] && break
    sleep 0.01
  done
  if [ ! -e "$interrupted_spawn_started" ]; then
    probe_failures=$((probe_failures + 1))
    echo 'FAIL: interrupted spawn probe did not reach the bounded child call' >&2
  fi
  kill -TERM "$interrupted_spawn_pid" 2>/dev/null || true
  if wait "$interrupted_spawn_pid"; then interrupted_spawn_rc=0; else interrupted_spawn_rc=$?; fi
  : > "$interrupted_spawn_release"
  sleep 0.02
  [ ! -e "$interrupted_spawn_cache.lock" ] \
    || { probe_failures=$((probe_failures + 1)); echo 'FAIL: interrupted spawn probe left its cache lock behind' >&2; }
  export HQ_TEST_SPAWN_CALLS="$probe_root/interrupted-spawn-retry-calls"
  interrupted_spawn_retry="$(hook_timeout_spawn_ms "$interrupted_spawn_cache" "$probe_root/bin/fake-bash" Linux)"
  case "$interrupted_spawn_retry" in ''|*[!0-9]*) probe_failures=$((probe_failures + 1)); echo 'FAIL: spawn probe could not retry after interruption' >&2 ;; esac
  probe_assert_eq 'interrupted spawn probe can be retried' x "$(<"$HQ_TEST_SPAWN_CALLS")"
  [ "$interrupted_spawn_rc" -ne 0 ] \
    || { probe_failures=$((probe_failures + 1)); echo 'FAIL: interrupted spawn probe unexpectedly completed' >&2; }
  if [ "$(hook_timeout_os_name "$(uname -s 2>/dev/null || true)")" = windows ]; then
    real_powershell=""
    for candidate in powershell.exe powershell pwsh.exe pwsh; do
      real_powershell="$(command -v "$candidate" 2>/dev/null || true)"
      [ -n "$real_powershell" ] && break
    done
    real_bash="$(command -v bash 2>/dev/null || true)"
    real_spawn_cache="$probe_root/session.spawn-windows-real-ms"
    real_spawn="$(hook_timeout_spawn_ms "$real_spawn_cache" "$real_bash" MINGW64_NT-10.0 "$real_powershell")"
    case "$real_spawn" in ''|*[!0-9]*) probe_failures=$((probe_failures + 1)); echo 'FAIL: Windows PowerShell spawn probe did not return milliseconds' >&2 ;; esac
    real_spawn_cached="$(hook_timeout_spawn_ms "$real_spawn_cache" "$real_bash" MINGW64_NT-10.0 "$real_powershell")"
    probe_assert_eq 'Windows PowerShell spawn result is cached' "$real_spawn" "$real_spawn_cached"
  fi
  if [ "$(hook_timeout_os_name "$(uname -s 2>/dev/null || true)")" != windows ] && command -v perl >/dev/null 2>&1; then
    fallback_bin="$probe_root/no-timeout-bin"
    mkdir -p "$fallback_bin"
    for fallback_tool in perl date rm mv; do
      fallback_path="$(command -v "$fallback_tool" 2>/dev/null || true)"
      if [ -n "$fallback_path" ]; then
        ln -s "$fallback_path" "$fallback_bin/$fallback_tool"
      else
        probe_failures=$((probe_failures + 1))
        printf 'FAIL: Perl timeout fallback requires %s\n' "$fallback_tool" >&2
      fi
    done
cat > "$fallback_bin/timeout" <<'EOF'
#!/bin/sh
printf 'Windows timeout usage help\n'
exit 1
EOF
    chmod +x "$fallback_bin/timeout"
    if PATH="$fallback_bin" hook_timeout_has_gnu_timeout; then
      probe_failures=$((probe_failures + 1))
      echo 'FAIL: non-GNU timeout was treated as GNU coreutils' >&2
    fi
    export HQ_TEST_SPAWN_CALLS="$probe_root/spawn-fallback-calls"
    fallback_cache="$probe_root/session.spawn-fallback-ms"
    spawn_fallback="$(PATH="$fallback_bin" hook_timeout_spawn_ms "$fallback_cache" "$probe_root/bin/fake-bash")"
    spawn_fallback_cached="$(PATH="$fallback_bin" hook_timeout_spawn_ms "$fallback_cache" "$probe_root/bin/fake-bash")"
    case "$spawn_fallback" in ''|*[!0-9]*) probe_failures=$((probe_failures + 1)); echo 'FAIL: Perl spawn fallback did not return milliseconds' >&2 ;; esac
    probe_assert_eq 'Perl spawn fallback cache is stable without GNU timeout' "$spawn_fallback" "$spawn_fallback_cached"
    probe_assert_eq 'Perl fallback measures the child shell once per session' 1 "$(wc -c < "$HQ_TEST_SPAWN_CALLS" | tr -d ' ')"
  fi
  unset HQ_TEST_SPAWN_CALLS
else
  probe_failures=$((probe_failures + 9))
  echo 'FAIL: Linux, Darwin, and Windows probe helpers are absent on the base revision' >&2
fi
[ "$probe_failures" -eq 0 ] || fail "platform probe regressions: $probe_failures assertion(s) failed"
pass 'load probes return fixture values and Windows spawn timing is cached'
fi

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
if [ "$slow_gate_rc" -ne 0 ]; then
  trigger_state=absent; [ ! -s "$R2/watchdog.trigger" ] || trigger_state=present
  armed_state=absent; [ ! -s "$R2/watchdog.armed" ] || armed_state=present
  watchdog_state="$(cat "$R2/watchdog.status" 2>/dev/null || printf 'none')"
  args_state=absent; [ ! -s "$R2/hq.args" ] || args_state=present
  report_lines=0; [ ! -f "$R2/hq.stdin" ] || report_lines="$(wc -l < "$R2/hq.stdin" | tr -d ' ')"
  ack_lines="$(wc -l < "$R2/hq.ack" | tr -d ' ')"
  printf 'diagnostic: trigger=%s watchdog_armed=%s watchdog_state=%s reporter_args=%s report_lines=%s acknowledgement_lines=%s\n' \
    "$trigger_state" "$armed_state" "$watchdog_state" "$args_state" "$report_lines" "$ack_lines" >&2
  fail "slow gate fixture did not reach reporter acknowledgement: $slow_gate_rc"
fi
[ "$(cat "$R2/watchdog.status" 2>/dev/null || true)" = report-returned ] \
  || fail "slow gate reporter returned without completing its watchdog state marker"
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
  and .metadata.bash_env_set == "set"
  and (.metadata.shell | type == "string" and contains("bash"))
  and .metadata.cwd_kind == "other"
  and (.metadata.timing_precision == "ms" or .metadata.timing_precision == "s")
  and (.metadata.nproc | type == "number" and . >= 1)
  and .metadata.hook_script == "detect-secrets.sh"
  and .metadata.exit_code == "running"
  and (.metadata.hook_sequence | type == "array" and length == 0)
  and ([.metadata | to_entries[] | select(.key != "hook_sequence") | .value | type]
       | all(. == "string" or . == "number" or . == "boolean"))
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
exec "${HQ_TEST_SYSTEM_JQ:?}" "$@"
EOF
chmod +x "$R6/bin/jq"
env PATH="$R6/bin:$PATH" HQ_TEST_HQ_ARGS="$R6/hq.args" HQ_TEST_HQ_STDIN="$R6/hq.stdin" HQ_TEST_HQ_ACK="$R6/hq.ack" \
  HQ_TEST_ROOT="$R6" HQ_TEST_SYSTEM_JQ="$SYSTEM_JQ" HQ_TEST_JQ_DELAY_MARKER="$R6/jq-delayed" HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2 \
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
fast_child_path="$R7/core/hooks/PreToolUse/10-fast-child.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'sleep 0.01' > "$fast_child_path"
chmod +x "$fast_child_path"
slow_child_path="$R7/core/hooks/PreToolUse/check-hq-update.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf MINGW64_NT-10.0' > "$R7/bin/uname"
printf '%s\n' '#!/usr/bin/env bash' '[ -n "${HQ_HOOK_TIMEOUT_SPAWN_SHELL:-}" ] || exit 127' 'printf 17' \
  > "$R7/bin/powershell.exe"
chmod +x "$R7/bin/uname" "$R7/bin/powershell.exe"
# shellcheck disable=SC2016 # This is source text for the fixture child script.
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'case "${HQ_HOOK_TIMEOUT_SENTRY:-1}" in 0) : ;; *) printf "%s\t%s\t%s\n" master-dispatch "${HQ_TEST_MASTER_PATH:?}" absolute > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"; printf "%s\t%s\t%s\n" master-dispatch "${HQ_TEST_MASTER_PATH:?}" relative >> "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"; while [ "$(wc -l < "${HQ_TEST_HQ_ACK:?}")" -lt 2 ]; do sleep 0.02; done ;; esac' 'printf "master block stdout"' 'printf "master block stderr" >&2' 'exit 2' > "$slow_child_path"
chmod +x "$slow_child_path"
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
with_stderr_bytes="$(wc -c < "$R7/err" | tr -d '[:space:]')"
without_stderr_bytes="$(wc -c < "$R7/without.err" | tr -d '[:space:]')"
stderr_parity="match"
cmp -s "$R7/err" "$R7/without.err" || stderr_parity="mismatch"
printf 'master child stderr parity: %s (watchdog=%s bytes, baseline=%s bytes)\n' \
  "$stderr_parity" "$with_stderr_bytes" "$without_stderr_bytes"
if [ "$stderr_parity" != "match" ]; then
  printf 'master child stderr with watchdog (%s bytes):\n' "$(wc -c < "$R7/err" | tr -d '[:space:]')" >&2
  diff -u "$R7/without.err" "$R7/err" >&2 || true
  fail "master child stderr changed when watchdog fired"
fi
[ "$(event_count "$R7")" = "3" ] || fail "slow master child should emit two warnings and one late finish"
jq -e '
  (.fingerprint | startswith("hook-timeout:PreToolUse:"))
  and .metadata.hook_name == "master-hook.sh"
  and .metadata.hook_path == $hook_path
' --arg hook_path "$master_hook_path" < <(sed '/^---EVENT---$/,$d' "$R7/hq.stdin") >/dev/null \
  || fail "master warning did not identify its dispatcher"
if ! jq -s -e --arg slow_child "${slow_child_path##*/}" --arg fast_child "${fast_child_path##*/}" '
  [ .[] | select(.type == "hook_late_finish"
    and .metadata.hook_script == "master-hook.sh") ] as $master_late
  | ($master_late | length) == 1
    and $master_late[0].metadata.slow_child == $slow_child
    and ($master_late[0].metadata.slow_child_ms | type == "number" and . > 0)
    and ($master_late[0].metadata.slow_child_ms >
      ([$master_late[0].metadata.hook_sequence[] | select(.script == $fast_child) | .ms][0]))
' < <(sed '/^---EVENT---$/d' "$R7/hq.stdin") >/dev/null; then
  jq -s '[.[] | {type, metadata: (.metadata | {hook_script, slow_child, slow_child_ms, hook_sequence})}]' \
    < <(sed '/^---EVENT---$/d' "$R7/hq.stdin") >&2 || true
  fail "master late event did not attribute the slowest completed child"
fi
pass "master late event attributes the slowest completed child"
if ! jq -s -e '
  [ .[] | select(.type == "hook_late_finish"
    and .metadata.hook_script == "master-hook.sh") ] as $master_late
  | ($master_late | length) == 1
    and $master_late[0].metadata.platform == "MINGW64_NT-10.0"
    and ($master_late[0].metadata.spawn_ms | type == "number" and . == 17)
' < <(sed '/^---EVENT---$/d' "$R7/hq.stdin") >/dev/null; then
  jq -s '[.[] | select(.type == "hook_late_finish" and .metadata.hook_script == "master-hook.sh")
    | .metadata | {platform, spawn_ms}]' < <(sed '/^---EVENT---$/d' "$R7/hq.stdin") >&2 || true
  fail "master Windows late event did not report the spawn-probe measurement"
fi
pass "master late event carries Windows spawn timing"

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
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s\n" "{\"hookSpecificOutput\":{\"additionalContext\":\"existing child context\"}}"' > "$slow_child_path"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s\n" "{\"decision\":\"block\",\"reason\":\"fixture block\"}"' > "$R7/core/hooks/PreToolUse/20-blocker.sh"
chmod +x "$R7/core/hooks/PreToolUse/20-blocker.sh"
PATH="$R7/bin:$PATH" HQ_TEST_HQ_ARGS="$R7/hq.args" HQ_TEST_HQ_STDIN="$R7/hq.stdin" \
  HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=1 HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2 \
  bash "$R7/.claude/hooks/master-hook.sh" PreToolUse >"$R7/blocked.out" 2>"$R7/blocked.err" <<<"$(payload master-session)"
jq -e '(.decision == "block") and (.hookSpecificOutput.hqSessionBlockedBy | endswith("20-blocker.sh"))' "$R7/blocked.out" >/dev/null \
  || fail "blocking child did not preserve master block output"
if grep -Fq "$slow_child_path" "$R7/blocked.out"; then
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
  delivered_hook_path="$(portable_native_path "$pending_hook_path")" \
    || fail "could not normalize $non_delivering_event breadcrumb path"
  write_timeout_breadcrumb "$R7_EVENT" "$pending_session" "$pending_hook_path" "$non_delivering_event" absolute
  pending_hash="$(sha256_fields "$pending_session")"
  pending_record="$R7_EVENT/workspace/.hook-timeout-breadcrumbs/$pending_hash/absolute-fixture.json"
  env PATH="$R7_EVENT/bin:$PATH" HQ_TEST_HQ_ARGS="$R7_EVENT/hq.args" HQ_TEST_HQ_STDIN="$R7_EVENT/hq.stdin" HQ_TEST_HQ_ACK="$R7_EVENT/hq.ack" \
    bash "$R7_EVENT/.claude/hooks/master-hook.sh" "$non_delivering_event" >"$R7_EVENT/non-delivering.out" 2>"$R7_EVENT/non-delivering.err" \
      <<<"$(payload_for_event "$non_delivering_event" "$pending_session")"
  [ -f "$pending_record" ] || fail "$non_delivering_event consumed a breadcrumb without delivering additionalContext"
  if grep -Fq "$delivered_hook_path" "$R7_EVENT/non-delivering.out"; then
    fail "$non_delivering_event emitted additionalContext instead of retaining it"
  fi
  [ ! -s "$R7_EVENT/non-delivering.err" ] || fail "$non_delivering_event changed master stderr"
  env PATH="$R7_EVENT/bin:$PATH" HQ_TEST_HQ_ARGS="$R7_EVENT/hq.args" HQ_TEST_HQ_STDIN="$R7_EVENT/hq.stdin" HQ_TEST_HQ_ACK="$R7_EVENT/hq.ack" \
    bash "$R7_EVENT/.claude/hooks/master-hook.sh" UserPromptSubmit >"$R7_EVENT/delivering.out" 2>"$R7_EVENT/delivering.err" \
      <<<"$(payload_for_event UserPromptSubmit "$pending_session")"
  # A missing match is the condition under test, not a shell error. Keep it
  # observable as count=0 so the assertion below emits its diagnostic.
  delivered_count="$(grep -oF "$delivered_hook_path" "$R7_EVENT/delivering.out" | wc -l || true)"
  [ "$delivered_count" -eq 1 ] \
    || fail "$non_delivering_event breadcrumb delivery count=$delivered_count (stdout: $(tr '\n' ' ' < "$R7_EVENT/delivering.out"); stderr: $(tr '\n' ' ' < "$R7_EVENT/delivering.err"))"
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
delivered_killed_child_path="$(portable_native_path "$killed_child_path")" \
  || fail "could not normalize killed dispatcher breadcrumb path"
killed_breadcrumb=""
pending_child_breadcrumbs=0
for candidate in "$killed_breadcrumb_dir"/*/*.json; do
  [ -f "$candidate" ] || continue
  if jq -e --arg hook_path "$delivered_killed_child_path" '.hook_path == $hook_path' "$candidate" >/dev/null 2>&1; then
    pending_child_breadcrumbs=$((pending_child_breadcrumbs + 1))
    if jq -e '.threshold == "absolute"' "$candidate" >/dev/null 2>&1; then
      killed_breadcrumb="$candidate"
    fi
  fi
done
[ -n "$killed_breadcrumb" ] || fail "killed dispatcher did not leave an absolute watchdog breadcrumb"
[ "$pending_child_breadcrumbs" -ge 1 ] || fail "killed dispatcher breadcrumb did not name the master hook"
jq -e '.invocation_id | type == "string" and length > 0' "$killed_breadcrumb" >/dev/null \
  || fail "killed dispatcher breadcrumb did not carry its invocation id"
killed_event_count="$(event_count "$R8K")"

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
injected_count="$(grep -ohF "$delivered_killed_child_path" "$R8K/first.out" "$R8K/second.out" | wc -l || true)"
[ "$injected_count" -eq "$pending_child_breadcrumbs" ] || fail "concurrent fires double-injected or dropped dispatcher breadcrumbs: expected $pending_child_breadcrumbs, got $injected_count"
[ "$(event_count "$R8K")" = "$killed_event_count" ] \
  || fail "a later invocation emitted hook_late_finish for an earlier invocation's breadcrumb"
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
cat > "$R10/bin/jq" <<'EOF'
#!/usr/bin/env bash
exec "${HQ_TEST_SYSTEM_JQ:?}" "$@"
EOF
chmod +x "$R10/bin/jq"
cat > "$R10/bin/hq" <<'EOF'
#!/usr/bin/env bash
# Simulates an installed pre-feature client which rejects the new subcommand.
touch "${HQ_TEST_HQ_OLD_ATTEMPT:?}"
cat >/dev/null
exit 2
EOF
chmod +x "$R10/bin/hq"
set +e
env PATH="$R10/bin:$TMP/bin:/usr/bin:/bin" HQ_TEST_HQ_ARGS="$R10/hq.args" HQ_TEST_HQ_STDIN="$R10/hq.stdin" HQ_TEST_HQ_ACK="$R10/hq.ack" \
  HQ_TEST_HQ_OLD_ATTEMPT="$R10/old-cli-attempt" HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$R10/watchdog.trigger" \
  HQ_HOOK_TIMEOUT_SENTRY_LEAD_SECONDS=2 \
  timeout 15s bash "$R10/.claude/hooks/hook-gate.sh" detect-secrets "$R10/.claude/hooks/detect-secrets.sh" \
    >"$R10/old-cli.out" 2>"$R10/old-cli.err" <<<"$(payload old-cli-session)"
old_cli_rc=$?
env PATH="$R10/bin:$TMP/bin:/usr/bin:/bin" HQ_TEST_HQ_ARGS="$R10/hq.args" HQ_TEST_HQ_STDIN="$R10/hq.stdin" HQ_TEST_HQ_ACK="$R10/hq.ack" \
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
env PATH="$R10/bin:$TMP/bin:/usr/bin:/bin" HQ_TEST_HQ_ARGS="$R10/hq.args" HQ_TEST_HQ_STDIN="$R10/hq.stdin" HQ_TEST_HQ_ACK="$R10/hq.ack" \
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
[ "$(event_count "$R11")" = "2" ] || fail "master without settings.json did not emit warning and late finish"
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

echo "[14] timeout warning fingerprints identify hooks independently of the install root"
R14_A="$(make_root fingerprint-a)"
R14_B="$(make_root fingerprint-b)"
relative_hook_path=".claude/hooks/identity-hook.sh"
hook_a="$R14_A/./$relative_hook_path"
hook_b="$R14_B/$relative_hook_path"

# Exercise both a trailing slash on --root and a leading ./ in the relative
# portion of the hook path. These spellings still identify the same hook.
run_watchdog_for_fingerprint "$R14_A" "$hook_a" PreToolUse same-hook-a "$R14_A/"
run_watchdog_for_fingerprint "$R14_B" "$hook_b" PreToolUse same-hook-b "$R14_B"
run_watchdog_for_fingerprint "$R14_A" "$R14_A/.claude/hooks/other-hook.sh" PreToolUse different-hook "$R14_A/"
run_watchdog_for_fingerprint "$R14_A" "$hook_a" PostToolUse different-event "$R14_A/"

outside_hook_path="$TMP/outside-install/.claude/hooks/outside-hook.sh"
run_watchdog_for_fingerprint "$R14_A" "$outside_hook_path" PreToolUse outside-root "$R14_A/"

symlinked_root_fingerprint=""
if [ "$(hook_timeout_os_name "$(uname -s 2>/dev/null || true)")" != windows ]; then
  R14_SYMLINK="$(make_root fingerprint-symlink)"
  R14_SYMLINK_ALIAS="$TMP/fingerprint-symlink-alias"
  ln -s "$R14_SYMLINK" "$R14_SYMLINK_ALIAS" || fail 'could not create fingerprint symlink fixture'
  resolved_symlink_root="$(cd "$R14_SYMLINK_ALIAS" && pwd -P)"
  [ "$resolved_symlink_root" != "$R14_SYMLINK_ALIAS" ] \
    || fail 'fingerprint symlink fixture did not create distinct path spellings'
  symlink_hook_path="$R14_SYMLINK_ALIAS/.claude/hooks/identity-hook.sh"
  run_watchdog_for_fingerprint "$R14_SYMLINK" "$symlink_hook_path" PreToolUse symlink-root "$R14_SYMLINK"
  symlinked_root_fingerprint="$(fingerprint_from_report "$R14_SYMLINK/symlink-root.hq.stdin")"
fi

same_hook_a_fingerprint="$(fingerprint_from_report "$R14_A/same-hook-a.hq.stdin")"
same_hook_b_fingerprint="$(fingerprint_from_report "$R14_B/same-hook-b.hq.stdin")"
different_hook_fingerprint="$(fingerprint_from_report "$R14_A/different-hook.hq.stdin")"
different_event_fingerprint="$(fingerprint_from_report "$R14_A/different-event.hq.stdin")"
outside_root_fingerprint="$(fingerprint_from_report "$R14_A/outside-root.hq.stdin")"
expected_relative_fingerprint="hook-timeout:PreToolUse:$(sha256_fields "$relative_hook_path")"
expected_outside_fingerprint="hook-timeout:PreToolUse:$(sha256_fields "outside-hook.sh")"

[ "$same_hook_a_fingerprint" = "$same_hook_b_fingerprint" ] \
  || fail "the same hook under two install roots produced different fingerprints: A=$same_hook_a_fingerprint B=$same_hook_b_fingerprint"
[ "$same_hook_a_fingerprint" = "$expected_relative_fingerprint" ] \
  || fail "a hook under the root did not fingerprint from its relative path"
[ "$same_hook_a_fingerprint" != "$different_hook_fingerprint" ] \
  || fail "different hooks under one root shared a fingerprint"
[ "$same_hook_a_fingerprint" != "$different_event_fingerprint" ] \
  || fail "one hook on different events shared a fingerprint"
[ "$outside_root_fingerprint" = "$expected_outside_fingerprint" ] \
  || fail "a hook outside the root did not fingerprint from its basename"
[ -z "$symlinked_root_fingerprint" ] || [ "$symlinked_root_fingerprint" = "$expected_relative_fingerprint" ] \
  || fail "a symlinked temp-root spelling did not fingerprint from its relative hook path"
case "$outside_root_fingerprint" in
  *"$outside_hook_path"*) fail "outside-root fingerprint embedded the absolute hook path" ;;
esac
pass "fingerprints are stable across install roots and remain condition-specific"

echo "[15] threshold metadata records shell, environment, cwd, and running state"
R15_META="$(make_root metadata-fields)"
touch "$R15_META/bash-env"

run_watchdog_metadata_case() {
  local root="$1" label="$2" env_mode="$3"
  local hook_path="$root/.claude/hooks/$label-hook.sh"
  local report="$root/$label.hq.stdin"
  printf '%s\t%s\t%s\n' master-child "$hook_path" relative > "$root/watchdog.trigger"
  if [ "$env_mode" = set ]; then
    env \
      BASH_ENV="$root/bash-env" \
      SHELL='C:\Program Files\Git\bin\zsh.EXE' \
      PATH="$root/bin:$PATH" \
      HQ_TEST_HQ_ARGS="$root/$label.hq.args" \
      HQ_TEST_HQ_STDIN="$report" \
      HQ_TEST_HQ_ACK="$root/$label.hq.ack" \
      HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2 \
      HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$root/watchdog.trigger" \
      timeout 15s bash "$root/.claude/hooks/hook-timeout-watchdog.sh" \
        --root "$root" --source master-child --hook-path "$hook_path" \
        --event PreToolUse --threshold relative --started-at 0 \
        >"$root/$label.out" 2>"$root/$label.err" \
        <<<"$(payload_for_event_with_cwd PreToolUse "$label-session" "$root")"
  else
    env \
      -u BASH_ENV \
      PATH="$root/bin:$PATH" \
      HQ_TEST_HQ_ARGS="$root/$label.hq.args" \
      HQ_TEST_HQ_STDIN="$report" \
      HQ_TEST_HQ_ACK="$root/$label.hq.ack" \
      HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2 \
      HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$root/watchdog.trigger" \
      timeout 15s bash "$root/.claude/hooks/hook-timeout-watchdog.sh" \
        --root "$root" --source master-child --hook-path "$hook_path" \
        --event PreToolUse --threshold relative --started-at 0 \
        >"$root/$label.out" 2>"$root/$label.err" \
        <<<"$(payload_for_event_with_cwd PreToolUse "$label-session" "$root")"
  fi
  [ "$(grep -c '^---EVENT---$' "$report" || true)" -ge 1 ] || fail "$label metadata case did not report"
  [ ! -s "$root/$label.err" ] || fail "$label metadata case wrote to stderr"
}

run_watchdog_metadata_case "$R15_META" metadata-set set
run_watchdog_metadata_case "$R15_META" metadata-unset unset
if ! jq -e '
  .type == "hook_timeout_warning"
  and .metadata.bash_env_set == "set"
  and (.metadata.shell | startswith("bash "))
  and (.metadata.timing_precision == "ms" or .metadata.timing_precision == "s")
  and .metadata.cwd_kind == "hq-root"
  and (.metadata.nproc | type == "number" and . >= 1)
  and .metadata.hook_script == "metadata-set-hook.sh"
  and .metadata.exit_code == "running"
  and (.metadata.hook_sequence | type == "array")
' < <(sed '/^---EVENT---$/,$d' "$R15_META/metadata-set.hq.stdin") >/dev/null; then
  jq -c '{type, metadata: (.metadata | {bash_env_set, shell, cwd_kind, nproc, hook_script, exit_code, hook_sequence})}' \
    < <(sed '/^---EVENT---$/,$d' "$R15_META/metadata-set.hq.stdin") >&2 || true
  fail "BASH_ENV=set metadata was incomplete or unsafe"
fi
jq -e '
  .type == "hook_timeout_warning"
  and .metadata.bash_env_set == "unset"
  and (.metadata.timing_precision == "ms" or .metadata.timing_precision == "s")
  and .metadata.cwd_kind == "hq-root"
  and .metadata.hook_script == "metadata-unset-hook.sh"
  and .metadata.exit_code == "running"
' < <(sed '/^---EVENT---$/,$d' "$R15_META/metadata-unset.hq.stdin") >/dev/null \
  || fail "BASH_ENV=unset metadata was incomplete or unsafe"
pass "threshold metadata exposes bounded runtime context without payload values"

echo "[16] late finish reporting includes a bounded hook journal"
R16="$(make_root late-finish)"
set_timeout "$R16" 'master-hook.sh" PreToolUse' 4
mkdir -p "$R16/core/hooks/PreToolUse"
for index in $(seq -w 1 25); do
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'exit 0' \
    > "$R16/core/hooks/PreToolUse/${index}-journal-fast.sh"
  chmod +x "$R16/core/hooks/PreToolUse/${index}-journal-fast.sh"
done
late_master_path="$R16/.claude/hooks/master-hook.sh"
# Normal child dispatch must append to the journal without taking the warning
# compaction path for every child. Count filesystem operations whose arguments
# name this journal so the test catches a reintroduction of per-child churn.
system_mkdir="$(command -v mkdir)"
system_tail="$(command -v tail)"
system_mv="$(command -v mv)"
: > "$R16/journal-fs-ops"
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in *hook-timeout-journal*) printf "%s\n" mkdir >> "${HQ_TEST_JOURNAL_FS_OPS:?}" ;; esac' \
  "exec \"$system_mkdir\" \"\$@\"" > "$R16/bin/mkdir"
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in *hook-timeout-journal*) printf "%s\n" tail >> "${HQ_TEST_JOURNAL_FS_OPS:?}" ;; esac' \
  "exec \"$system_tail\" \"\$@\"" > "$R16/bin/tail"
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in *hook-timeout-journal*) printf "%s\n" mv >> "${HQ_TEST_JOURNAL_FS_OPS:?}" ;; esac' \
  "exec \"$system_mv\" \"\$@\"" > "$R16/bin/mv"
chmod +x "$R16/bin/mkdir" "$R16/bin/tail" "$R16/bin/mv"
# shellcheck disable=SC2016 # These quoted lines are source text for the fixture child.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'cat >/dev/null' \
  'printf "%s\t%s\t%s\n" master-dispatch "$HQ_TEST_MASTER_PATH" absolute > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"' \
  'printf "%s\t%s\t%s\n" master-dispatch "$HQ_TEST_MASTER_PATH" relative >> "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"' \
  'while [ "$(wc -l < "${HQ_TEST_HQ_ACK:?}")" -lt 2 ]; do sleep 0.02; done' \
  'printf "late stdout"' \
  'exit 7' > "$R16/core/hooks/PreToolUse/99-late-finish.sh"
chmod +x "$R16/core/hooks/PreToolUse/99-late-finish.sh"
# Git Bash startup cost across the deliberate 25-hook journal fixture can
# exceed the Linux-oriented 15-second harness budget on Windows.
set +e
env \
  BASH_ENV= \
  PATH="$R16/bin:$PATH" \
  HQ_TEST_HQ_ARGS="$R16/hq.args" \
  HQ_TEST_HQ_STDIN="$R16/hq.stdin" \
  HQ_TEST_HQ_ACK="$R16/hq.ack" \
  HQ_TEST_JOURNAL_FS_OPS="$R16/journal-fs-ops" \
  HQ_TEST_MASTER_PATH="$late_master_path" \
  HQ_HARNESS=codex \
  SHELL=/bin/zsh \
  HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=1 \
  HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=1 \
  HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$R16/watchdog.trigger" \
  timeout 45s bash "$R16/.claude/hooks/master-hook.sh" PreToolUse \
  >"$R16/out" 2>"$R16/err" <<<"$(payload_for_event PreToolUse late-finish-session)"
late_finish_rc=$?
set -e
[ "$late_finish_rc" -eq 7 ] || fail "late-finish fixture changed its child exit code: $late_finish_rc"
[ "$(event_count "$R16")" = "3" ] || fail "late-finish fixture should emit two warnings and one completion event"
jq -s -e --arg hook_path "$late_master_path" '
  length == 3
  and ([.[] | select(.type == "hook_timeout_warning")] | length == 2)
  and ([.[] | select(.type == "hook_late_finish")] | length == 1)
  and (all(.[]; .metadata.hook_path == $hook_path))
  and (all(.[]; .metadata.hook_script == "master-hook.sh"))
  and (all(.[]; (.metadata.hook_sequence | type == "array" and length == 20)))
  and (all(.[]; ([.metadata.hook_sequence[] | .script] | all(contains("/") | not))))
  and (all(.[]; ([.metadata.hook_sequence[] | .event] | all(. == "PreToolUse"))))
  and (all(.[]; ([.metadata.hook_sequence[] | .ms] | all(type == "number"))))
  and (all(.[]; .metadata.declared_timeout_ms == 30000))
  and ([.[] | .metadata.watchdog_timeout_ms] | sort == [1000, 1000, 29000])
  and (all(.[]; (.metadata.shell | startswith("bash "))))
  and (all(.[]; (.metadata.timing_precision == "ms" or .metadata.timing_precision == "s")))
  and ([.[] | .fingerprint] | unique | length == 1)
  and ([.[] | select(.type == "hook_late_finish") | .metadata.final_elapsed_ms]
       | all(type == "number" and . >= 0))
  and ([.[] | select(.type == "hook_late_finish") | .metadata.exit_code] == [7])
' < <(sed '/^---EVENT---$/d' "$R16/hq.stdin") >/dev/null \
  || fail "late-finish event or bounded journal metadata was incomplete"
[ ! -s "$R16/err" ] || fail "late-finish instrumentation changed master stderr"
late_journal_hash="$(sha256_fields late-finish-session)"
late_journal_meta="$R16/workspace/.hook-timeout-journal/$late_journal_hash.tsv.meta"
grep -Fxq 'bash_env_set=set' "$late_journal_meta" \
  || fail "master journal did not record its BASH_ENV state"
grep -Eq '^timing_precision=(ms|s)$' "$late_journal_meta" \
  || fail "master journal did not record timing precision"
journal_fs_ops_count="$(wc -l < "$R16/journal-fs-ops")"
[ "$journal_fs_ops_count" -le 10 ] \
  || fail "normal dispatch performed per-child journal filesystem churn: $journal_fs_ops_count operations"
late_journal_file="${late_journal_meta%.meta}"
journal_line_count="$(wc -l < "$late_journal_file" 2>/dev/null || printf '0')"
[ "$journal_line_count" -le 40 ] || fail "completed hook history exceeded its 40-row bound: $journal_line_count rows"
if awk -F '\t' 'NF == 5 && $3 == "running" { found = 1 } END { exit(found ? 0 : 1) }' "$late_journal_file"; then
  fail "completed hook history retained per-child running records"
fi
pass "late finish is emitted once with final duration, exit code, and last 20 hooks"

echo "[17] child timeout emits one completion event with the timeout exit code"
R17="$(make_root child-timeout)"
case "$(uname -s 2>/dev/null || printf unknown)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
    # Exercise the macOS-style Perl alarm timeout shim even when GNU timeout
    # exists on the test host. Its SIGALRM status must map to the hook contract.
    cat > "$R17/bin/timeout" <<'EOF'
#!/usr/bin/env bash
seconds="${1%s}"
shift
exec perl -e 'alarm shift; exec @ARGV or exit 127' "$seconds" "$@"
EOF
    chmod +x "$R17/bin/timeout"
    ;;
esac
mkdir -p "$R17/core/hooks/PreToolUse"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'sleep 2' \
  > "$R17/core/hooks/PreToolUse/10-timeout-child.sh"
chmod +x "$R17/core/hooks/PreToolUse/10-timeout-child.sh"
set +e
env \
  BASH_ENV= \
  PATH="$R17/bin:$PATH" \
  HQ_TEST_HQ_ARGS="$R17/hq.args" \
  HQ_TEST_HQ_STDIN="$R17/hq.stdin" \
  HQ_TEST_HQ_ACK="$R17/hq.ack" \
  HQ_HOOK_TIMEOUT_SENTRY=0 \
  HQ_MASTER_CHILD_TIMEOUT=1 \
  timeout 15s bash "$R17/.claude/hooks/master-hook.sh" PreToolUse \
  >"$R17/out" 2>"$R17/err" <<<"$(payload_for_event PreToolUse child-timeout-session)"
child_timeout_rc=$?
set -e
[ "$child_timeout_rc" -eq 124 ] || fail "child timeout changed its declared timeout exit: $child_timeout_rc"
[ "$(event_count "$R17")" = "1" ] || fail "child timeout should emit one completion event"
jq -e --arg hook_path "$R17/core/hooks/PreToolUse/10-timeout-child.sh" '
  .type == "hook_timeout_exceeded"
  and (.fingerprint | startswith("hook-timeout:PreToolUse:"))
  and .metadata.hook_path == $hook_path
  and .metadata.hook_script == "10-timeout-child.sh"
  and .metadata.exit_code == 124
  and .metadata.declared_timeout_ms == 1000
  and .metadata.watchdog_timeout_ms == 1000
  and (.metadata.timing_precision == "ms" or .metadata.timing_precision == "s")
  and (.metadata.final_elapsed_ms | type == "number" and . >= 900)
  and (.metadata.hook_sequence | type == "array")
' < <(sed '/^---EVENT---$/,$d' "$R17/hq.stdin") >/dev/null \
  || fail "child timeout event omitted final duration or exit code"
[ ! -s "$R17/err" ] || fail "child timeout instrumentation changed master stderr"
pass "declared child timeout is reported with its measured completion details"

echo "[17b] a child that returns 124 is not misclassified as a timeout"
R17_STATUS="$(make_root child-status-124)"
mkdir -p "$R17_STATUS/core/hooks/PreToolUse"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'exit 124' \
  > "$R17_STATUS/core/hooks/PreToolUse/10-status-124-child.sh"
chmod +x "$R17_STATUS/core/hooks/PreToolUse/10-status-124-child.sh"
set +e
env \
  BASH_ENV= \
  PATH="$R17_STATUS/bin:$PATH" \
  HQ_TEST_HQ_ARGS="$R17_STATUS/hq.args" \
  HQ_TEST_HQ_STDIN="$R17_STATUS/hq.stdin" \
  HQ_TEST_HQ_ACK="$R17_STATUS/hq.ack" \
  HQ_HOOK_TIMEOUT_SENTRY=0 \
  HQ_MASTER_CHILD_TIMEOUT=1 \
  timeout 15s bash "$R17_STATUS/.claude/hooks/master-hook.sh" PreToolUse \
  >"$R17_STATUS/out" 2>"$R17_STATUS/err" <<<"$(payload_for_event PreToolUse child-status-124-session)"
status_124_rc=$?
set -e
[ "$status_124_rc" -eq 124 ] || fail "legitimate child status 124 was changed: $status_124_rc"
[ "$(event_count "$R17_STATUS")" = "0" ] || fail "legitimate child status 124 was reported as a timeout"
[ ! -s "$R17_STATUS/err" ] || fail "legitimate child status 124 changed master stderr"
pass "out-of-band completion marker distinguishes status 124 from a timeout"

echo "[18] warning compaction recovers an abandoned journal lock"
R18_LOCK="$(make_root stale-journal-lock)"
set_timeout "$R18_LOCK" 'master-hook.sh" PreToolUse' 4
mkdir -p "$R18_LOCK/core/hooks/PreToolUse"
stale_lock_session="stale-journal-lock-session"
stale_lock_hash="$(sha256_fields "$stale_lock_session")"
stale_lock_journal_dir="$R18_LOCK/workspace/.hook-timeout-journal"
stale_lock_journal="$stale_lock_journal_dir/$stale_lock_hash.tsv"
mkdir -p "$stale_lock_journal_dir"
for index in $(seq -w 1 50); do
  printf 'pre-%s\tPreToolUse\t1\n' "$index"
done > "$stale_lock_journal"
mkdir "$stale_lock_journal.lock"
printf '999999999\n' > "$stale_lock_journal.lock/pid"
stale_lock_child="$R18_LOCK/core/hooks/PreToolUse/10-stale-lock-child.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' \
  'printf "%s\\t%s\\t%s\\n" master-dispatch "${HQ_TEST_MASTER_PATH:?}" absolute > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"' \
  'printf "%s\\t%s\\t%s\\n" master-dispatch "${HQ_TEST_MASTER_PATH:?}" relative >> "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"' \
  'while [ "$(wc -l < "${HQ_TEST_HQ_ACK:?}")" -lt 2 ]; do sleep 0.02; done' \
  > "$stale_lock_child"
chmod +x "$stale_lock_child"
set +e
env \
  PATH="$R18_LOCK/bin:$PATH" \
  HQ_TEST_HQ_ARGS="$R18_LOCK/hq.args" \
  HQ_TEST_HQ_STDIN="$R18_LOCK/hq.stdin" \
  HQ_TEST_HQ_ACK="$R18_LOCK/hq.ack" \
  HQ_TEST_MASTER_PATH="$R18_LOCK/.claude/hooks/master-hook.sh" \
  HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=1 \
  HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=1 \
  HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$R18_LOCK/watchdog.trigger" \
  timeout 15s bash "$R18_LOCK/.claude/hooks/master-hook.sh" PreToolUse \
  >"$R18_LOCK/out" 2>"$R18_LOCK/err" <<<"$(payload_for_event PreToolUse "$stale_lock_session")"
stale_lock_rc=$?
set -e
[ "$stale_lock_rc" -eq 0 ] || fail "stale journal lock fixture changed master exit: $stale_lock_rc"
[ "$(event_count "$R18_LOCK")" = "3" ] || fail "stale journal lock fixture did not emit both warnings and late finish"
[ ! -e "$stale_lock_journal.lock" ] || fail "stale journal lock was not reclaimed"
jq -s -e --arg child "$(basename "$stale_lock_child")" '
  length == 3
  and any(.[]; any(.metadata.hook_sequence[]; .script == $child))
' < <(sed '/^---EVENT---$/d' "$R18_LOCK/hq.stdin") >/dev/null \
  || fail "stale journal lock prevented compaction from preserving the current child"
[ ! -s "$R18_LOCK/err" ] || fail "stale journal lock recovery changed master stderr"
pass "stale journal lock recovery preserves the bounded hook sequence"

echo "[19] warning reporting completes before the watchdog group is stopped"
R19_REPORT="$(make_root reporter-completion)"
set_timeout "$R19_REPORT" 'master-hook.sh" PreToolUse' 4
mkdir -p "$R19_REPORT/core/hooks/PreToolUse"
cat > "$R19_REPORT/bin/hq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'printf "killed\\n" >> "${HQ_TEST_HQ_KILLED_FILE:?}"; exit 143' TERM
printf '%s\n' "${HQ_NO_UPDATE_CHECK:-unset}" >> "${HQ_TEST_HQ_UPDATE_CHECK:?}"
printf '%s\n' "$*" >> "${HQ_TEST_HQ_ARGS:?}"
event_json="$(cat)"
printf '%s' "$event_json" >> "${HQ_TEST_HQ_STDIN:?}"
printf 'reported\n' >> "${HQ_TEST_HQ_ACK:?}"
case "$event_json" in
  *'"type":"hook_timeout_warning"'*)
  : > "${HQ_TEST_HQ_ENTERED_FILE:?}"
  while [ ! -e "${HQ_TEST_HQ_RELEASE_FILE:?}" ]; do sleep 0.02; done
  ;;
esac
printf '\n---EVENT---\n' >> "${HQ_TEST_HQ_STDIN:?}"
EOF
chmod +x "$R19_REPORT/bin/hq"
reporter_child="$R19_REPORT/core/hooks/PreToolUse/10-reporter-completion-child.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' \
  'printf "%s\\t%s\\t%s\\n" master-dispatch "${HQ_TEST_MASTER_PATH:?}" absolute > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"' \
  'printf "%s\\t%s\\t%s\\n" master-dispatch "${HQ_TEST_MASTER_PATH:?}" relative >> "${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:?}"' \
  'while [ "$(wc -l < "${HQ_TEST_HQ_ACK:?}")" -lt 2 ]; do sleep 0.02; done' \
  > "$reporter_child"
chmod +x "$reporter_child"
: > "$R19_REPORT/reporter-entered"
: > "$R19_REPORT/reporter-killed"
env \
  PATH="$R19_REPORT/bin:$PATH" \
  HQ_TEST_HQ_ARGS="$R19_REPORT/hq.args" \
  HQ_TEST_HQ_STDIN="$R19_REPORT/hq.stdin" \
  HQ_TEST_HQ_ACK="$R19_REPORT/hq.ack" \
  HQ_TEST_HQ_RELEASE_FILE="$R19_REPORT/release-reporters" \
  HQ_TEST_HQ_ENTERED_FILE="$R19_REPORT/reporter-entered" \
  HQ_TEST_HQ_KILLED_FILE="$R19_REPORT/reporter-killed" \
  HQ_HOOK_TIMEOUT_SENTRY_TEST_WAIT_FILE="$R19_REPORT/wait-entered" \
  HQ_TEST_MASTER_PATH="$R19_REPORT/.claude/hooks/master-hook.sh" \
  HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=1 \
  HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=1 \
  HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$R19_REPORT/watchdog.trigger" \
  bash "$R19_REPORT/.claude/hooks/master-hook.sh" PreToolUse \
  >"$R19_REPORT/out" 2>"$R19_REPORT/err" <<<"$(payload_for_event PreToolUse reporter-completion-session)" &
reporter_master_pid=$!
for _ in $(seq 1 750); do
  [ -e "$R19_REPORT/reporter-entered" ] && break
  sleep 0.02
done
[ -e "$R19_REPORT/reporter-entered" ] || fail "reporter completion fixture did not block warning delivery"
for _ in $(seq 1 750); do
  [ -e "$R19_REPORT/wait-entered" ] && break
  sleep 0.02
done
[ -e "$R19_REPORT/wait-entered" ] || fail "master did not enter the reporter completion wait"
sleep 0.5
if kill -0 "$reporter_master_pid" >/dev/null 2>&1; then
  : > "$R19_REPORT/master-waited"
fi
sleep 0.25
: > "$R19_REPORT/release-reporters"
set +e
wait "$reporter_master_pid"
reporter_completion_rc=$?
set -e
[ "$reporter_completion_rc" -eq 0 ] || fail "reporter completion fixture changed master exit: $reporter_completion_rc"
[ -e "$R19_REPORT/master-waited" ] || fail "master stopped before warning reporters completed"
[ ! -s "$R19_REPORT/reporter-killed" ] || fail "warning reporter was killed before it completed"
[ "$(event_count "$R19_REPORT")" = "3" ] || fail "master stopped the warning reporters before they completed"
[ ! -s "$R19_REPORT/err" ] || fail "reporter completion wait changed master stderr"
pass "warning reporters finish before their process group is stopped"

echo "[20] every timeout reporter disables hq self-update"
[ -s "$HQ_TEST_HQ_UPDATE_CHECK" ] || fail "no hq timeout reporter invocation was recorded"
if grep -qv '^1$' "$HQ_TEST_HQ_UPDATE_CHECK"; then
  fail "a timeout reporter invoked hq without HQ_NO_UPDATE_CHECK=1"
fi
pass "every timeout reporter sets HQ_NO_UPDATE_CHECK=1"

echo "ALL PASS: hook-timeout-sentry"
