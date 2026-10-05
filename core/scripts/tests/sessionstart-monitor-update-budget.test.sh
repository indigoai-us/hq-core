#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
BASH_BIN="$(type -P bash)"
TMP="$(mktemp -d)"
FAILURES=0
PASSES=0
SLOW_PIDS="$TMP/slow.pids"
NPM_PREFIX_TIMEOUT_SECONDS=2
NPM_PREFIX_SLOW_SECONDS=3
UPDATE_PROBE_OUTER_SECONDS=2
# Windows CI has measured 2.071s for update-heal through this harness even
# with its one-second hook probe. Keep the 1s assertion below and allow process
# startup/reaping headroom at the outer harness boundary.
case "${OSTYPE:-}" in
  msys*|cygwin*) NPM_PREFIX_TIMEOUT_SECONDS=4; NPM_PREFIX_SLOW_SECONDS=8; UPDATE_PROBE_OUTER_SECONDS=4 ;;
esac

cleanup() {
  if [ "${KEEP_SESSIONSTART_TEST_TMP:-0}" = 1 ]; then
    printf 'TEST_TMP=%s\n' "$TMP"
    return
  fi
  if [ -f "$SLOW_PIDS" ]; then
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
    done < "$SLOW_PIDS"
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { printf 'PASS: %s\n' "$*"; PASSES=$((PASSES + 1)); }

mkdir -p "$TMP/root/.claude/hooks" "$TMP/root/core/scripts" "$TMP/bin" "$TMP/shadow-tools"
: > "$TMP/root/.claude/hooks/hook-gate.sh"
cat > "$TMP/root/core/scripts/hook-lib.sh" <<'EOF'
hq_hook_session_key_from_payload() { printf 'test-session'; }
hq_hook_warning_once() { return 1; }
EOF

cat > "$TMP/bin/hq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-} ${2:-} ${3:-}" >> "${HQ_TEST_HQ_CALLS:?}"
if [ "${1:-}" = monitor ] && [ "${2:-}" = enabled ]; then
  case "${HQ_TEST_HQ_MODE:-}" in
    slow-monitor)
      printf '%s\n' "$BASHPID" >> "$HQ_TEST_SLOW_PIDS"
      exec sleep 3
      ;;
    slow-help|monitor-off) exit 1 ;;
    *) exit 0 ;;
  esac
fi
if [ "${1:-}" = --help ] && [ "${HQ_TEST_HQ_MODE:-}" = slow-help ]; then
  printf '%s\n' "$BASHPID" >> "$HQ_TEST_SLOW_PIDS"
  exec sleep 3
fi
if [ "${1:-}" = --version ]; then
  case "${HQ_TEST_HQ_MODE:-}" in
    slow-version)
    printf '%s\n' "$BASHPID" >> "$HQ_TEST_SLOW_PIDS"
    exec sleep "${HQ_TEST_PROBE_SLOW_SECONDS:?}"
    ;;
    update-current) printf 'hq 5.331.0\n' ;;
  esac
fi
exit 0
EOF

cat > "$TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HQ_TEST_NPM_CALLS:?}"
if [ "${HQ_TEST_NPM_MODE:-}" = slow-prefix ] && [ "${1:-}" = config ] && [ "${2:-}" = get ] && [ "${3:-}" = prefix ]; then
  printf '%s\n' "$BASHPID" >> "$HQ_TEST_SLOW_PIDS"
  exec sleep "${HQ_TEST_NPM_SLOW_SECONDS:-3}"
fi
printf '%s\n' "${HQ_TEST_NPM_PREFIX:-$TMP/npm-global}"
EOF
chmod +x "$TMP/bin/hq" "$TMP/bin/npm"

add_shadow_tool() {
  local utility="$1" utility_path utility_q
  utility_path="$(command -v "$utility" 2>/dev/null || true)"
  [ -n "$utility_path" ] || return 0
  printf -v utility_q '%q' "$utility_path"
  printf '#!/bin/bash\nexec %s "$@"\n' "$utility_q" > "$TMP/shadow-tools/$utility"
  chmod +x "$TMP/shadow-tools/$utility"
}

# The check-updater calls this synchronously before its CLI-floor check.
cat > "$TMP/root/core/scripts/remove-stray-gate-hooks.sh" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$HQ_TEST_HEAL_CALLS"
if [ "${HQ_TEST_HEAL_MODE:-}" = slow-heal ]; then
  printf '%s\n' "$BASHPID" >> "$HQ_TEST_SLOW_PIDS"
  exec sleep "${HQ_TEST_PROBE_SLOW_SECONDS:?}"
fi
exit 0
EOF
chmod +x "$TMP/root/core/scripts/remove-stray-gate-hooks.sh"

# Keep hq and npm under test in the first PATH directory while keeping the
# updater from discovering unrelated host-installed hq/pnpm binaries.
for utility in awk bash cat date dirname grep head mkdir mktemp mv nohup perl pkill rm sed setsid sh sleep stat timeout tr uname; do
  add_shadow_tool "$utility"
done
TEST_PATH="$TMP/bin:$TMP/shadow-tools"

run_timed() {
  local hook="$1" mode="$2" label="$3" npm_mode="${4:-}" seconds="${5:-2}"
  local path_override="${6:-$TEST_PATH}" npm_prefix="${7:-$TMP/npm-global}" rc=0
  : > "$SLOW_PIDS"
  : > "$TMP/$label.timing"
  set +e
  timeout "${seconds}s" env \
    BASH_ENV= \
    HQ_ROOT="$TMP/root" \
    CLAUDE_PROJECT_DIR="$TMP/root" \
    HQ_CHECKPOINT_RUNTIME=codex \
    HQ_TEST_HQ_MODE="$mode" \
    HQ_TEST_HQ_CALLS="$TMP/$label.hq.calls" \
    HQ_TEST_GH_CALLS="$TMP/$label.gh.calls" \
    HQ_TEST_HEAL_CALLS="$TMP/$label.heal.calls" \
    HQ_TEST_HEAL_MODE="$mode" \
    HQ_TEST_SLOW_PIDS="$SLOW_PIDS" \
    HQ_TEST_PROBE_SLOW_SECONDS="$((UPDATE_PROBE_OUTER_SECONDS + 2))" \
    HQ_TEST_NPM_MODE="$npm_mode" \
    HQ_TEST_NPM_SLOW_SECONDS="$NPM_PREFIX_SLOW_SECONDS" \
    HQ_TEST_NPM_CALLS="$TMP/$label.npm.calls" \
    HQ_TEST_NPM_PREFIX="$npm_prefix" \
    HQ_TEST_TIMING_FILE="$TMP/$label.timing" \
    HQ_TEST_ALT_CALLS="$TMP/$label.alt.calls" \
    PATH="$path_override" \
    "$BASH_BIN" "$hook" > "$TMP/$label.out" 2> "$TMP/$label.err"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    fail "$label exceeded the ${seconds}-second SessionStart bound (exit $rc)"
    return 1
  fi
  [ ! -s "$TMP/$label.err" ] || fail "$label wrote stderr: $(cat "$TMP/$label.err")"
  return 0
}

assert_slow_pids_reaped() {
  local label="$1" pid found=0 alive=0
  if [ ! -s "$SLOW_PIDS" ]; then
    fail "$label did not record a slow fixture pid"
    return
  fi
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    found=1
    if kill -0 "$pid" 2>/dev/null; then
      alive=1
      fail "$label left slow fixture pid $pid alive"
    fi
  done < "$SLOW_PIDS"
  [ "$found" -eq 1 ] || fail "$label did not record a valid slow fixture pid"
  [ "$found" -eq 1 ] && [ "$alive" -eq 0 ] \
    && pass "$label reaped every slow fixture pid"
}

assert_probe_timing() {
  local label="$1" probe="$2" timing_line="" budget elapsed
  if [ -f "$TMP/$label.timing" ]; then
    timing_line="$(grep -E "^probe=${probe} budget_ms=[0-9]+ elapsed_ms=[0-9]+$" "$TMP/$label.timing" | head -1 || true)"
  fi
  budget="${timing_line#*budget_ms=}"
  budget="${budget%% *}"
  elapsed="${timing_line##*elapsed_ms=}"
  printf 'TIMING: %s %s\n' "$label" "${timing_line:-probe=$probe timing=missing}"
  if [[ "$budget" =~ ^[0-9]+$ ]] && [ "$budget" -eq 1000 ] \
    && [[ "$elapsed" =~ ^[0-9]+$ ]] && [ "$elapsed" -ge 900 ] && [ "$elapsed" -lt 1900 ]; then
    pass "$label records the one-second internal probe bound (${elapsed}ms)"
  else
    fail "$label did not record a one-second internal probe measurement for ${probe} (got '${timing_line:-none}')"
  fi
}

MONITOR="$ROOT/.claude/hooks/hq-monitor-session-start.sh"
UPDATE="$ROOT/.claude/hooks/check-hq-update.sh"

if run_timed "$MONITOR" slow-monitor monitor-command; then
  grep -Fq 'monitor enabled' "$TMP/monitor-command.hq.calls" \
    && pass 'slow hq monitor enabled check returns within the bound' \
    || fail 'monitor enabled delay fixture was not invoked'
fi

if run_timed "$MONITOR" slow-help monitor-help; then
  grep -Fq 'monitor enabled' "$TMP/monitor-help.hq.calls" \
    && grep -Fq -- '--help' "$TMP/monitor-help.hq.calls" \
    && pass 'slow hq help fallback returns within the bound' \
    || fail 'monitor help delay fixture was not invoked'
fi

if run_timed "$UPDATE" slow-heal update-heal "" "$UPDATE_PROBE_OUTER_SECONDS"; then
  grep -Fq 'called' "$TMP/update-heal.heal.calls" \
    && pass 'slow settings-heal helper returns within the bound' \
    || fail 'settings-heal delay fixture was not invoked'
fi
assert_slow_pids_reaped update-heal
assert_probe_timing update-heal settings-heal

mkdir -p "$TMP/root/workspace"
if run_timed "$UPDATE" slow-version update-version "" "$UPDATE_PROBE_OUTER_SECONDS"; then
  grep -Fq -- '--version' "$TMP/update-version.hq.calls" \
    && pass 'slow hq version probe returns within the bound' \
    || fail 'hq version delay fixture was not invoked'
fi
assert_slow_pids_reaped update-version
assert_probe_timing update-version cli-version

# The internal one-second watchdog is separate from the test harness's
# SessionStart limit. A stubborn fixture must still be caught by
# the outer limit if it ignores TERM instead of completing on its own.
cat > "$TMP/ignore-watchdog.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep "${HQ_TEST_STUBBORN_SLEEP_SECONDS:?}"
EOF
chmod +x "$TMP/ignore-watchdog.sh"
ignore_watchdog_started_us="${EPOCHREALTIME/./}"
set +e
HQ_TEST_STUBBORN_SLEEP_SECONDS="$((UPDATE_PROBE_OUTER_SECONDS + 5))" \
  timeout -k 1s "${UPDATE_PROBE_OUTER_SECONDS}s" "$BASH_BIN" "$TMP/ignore-watchdog.sh" \
  > "$TMP/ignore-watchdog.out" 2> "$TMP/ignore-watchdog.err"
ignore_watchdog_rc=$?
set -e
ignore_watchdog_elapsed_us=$(( ${EPOCHREALTIME/./} - ignore_watchdog_started_us ))
printf 'TIMING: term-ignoring-control limit_s=%s elapsed_us=%s exit=%s\n' \
  "$UPDATE_PROBE_OUTER_SECONDS" "$ignore_watchdog_elapsed_us" "$ignore_watchdog_rc"
if [ "$ignore_watchdog_rc" -eq 137 ] \
  && [ "$ignore_watchdog_elapsed_us" -lt "$(((UPDATE_PROBE_OUTER_SECONDS + 2) * 1000000))" ]; then
  pass "TERM-ignoring control is killed after its grace period in under $((UPDATE_PROBE_OUTER_SECONDS + 2)) seconds (exit 137)"
else
  fail "TERM-ignoring control exceeded $((UPDATE_PROBE_OUTER_SECONDS + 2)) seconds or returned $ignore_watchdog_rc instead of 137"
fi

# Release discovery is advisory and its uncached network wait must stay short.
mkdir -p "$TMP/root/core"
printf 'hqVersion: "15.0.131"\n' > "$TMP/root/core/core.yaml"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HQ_TEST_GH_CALLS"
exec sleep 5
EOF
chmod +x "$TMP/bin/gh"
if run_timed "$UPDATE" update-current update-gh-network fast 4; then
  grep -Fq 'auth status' "$TMP/update-gh-network.gh.calls" \
    && pass 'stalled GitHub auth probe returns within the shortened deadline' \
    || fail 'GitHub timeout fixture was not invoked'
fi
rm -f "$TMP/bin/gh" "$TMP/root/core/core.yaml"

# The normal monitor-enabled path keeps its existing user-visible text exactly.
if run_timed "$MONITOR" fast-monitor monitor-normal; then
  expected='For long waits, use `hq monitor start`; it checks in every 55 minutes to keep prompt caching within the one-hour window.'
  actual="$(cat "$TMP/monitor-normal.out")"
  [ "$actual" = "$expected" ] && pass 'normal monitor output is byte-identical' \
    || fail "normal monitor output changed: $actual"
fi

# Force the legacy-CLI discovery path. npm's global-prefix lookup must not hold
# SessionStart while the package manager is stalled.
cat > "$TMP/bin/hq" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf 'hq 5.0.0\n'; fi
EOF
chmod +x "$TMP/bin/hq"
if run_timed "$UPDATE" unused update-npm-prefix slow-prefix "$NPM_PREFIX_TIMEOUT_SECONDS"; then
  grep -Fq 'config get prefix' "$TMP/update-npm-prefix.npm.calls" \
    || fail 'npm prefix delay fixture was not invoked'
  [ ! -s "$TMP/update-npm-prefix.out" ] \
    && pass 'timed-out npm prefix lookup conservatively skips the auto-update advisory' \
    || fail 'timed-out npm prefix lookup emitted an unsafe update advisory'
fi

# Many PATH entries must not multiply the per-binary probe budget without a
# total bound. Each alternate CLI takes a quarter-second and reports older.
mkdir -p "$TMP/slow-global/bin"
cat > "$TMP/slow-global/bin/hq" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'probe\n' >> "$HQ_TEST_ALT_CALLS"
  sleep 0.25
  printf 'hq 1.0.0\n'
fi
EOF
chmod +x "$TMP/slow-global/bin/hq"
printf '%s\n' '#!/usr/bin/env bash' 'if [ "${1:-}" = --version ]; then printf "hq 5.0.0\\n"; fi' > "$TMP/bin/hq"
chmod +x "$TMP/bin/hq"
ALT_PATH_DIRS=()
for index in $(seq 1 32); do
  dir="$TMP/path-$index"
  mkdir -p "$dir"
  ln -s "$TMP/slow-global/bin/hq" "$dir/hq"
  ALT_PATH_DIRS+=("$dir")
done
ALT_PATH="$TMP/bin"
for dir in "${ALT_PATH_DIRS[@]}"; do ALT_PATH="$ALT_PATH:$dir"; done
ALT_PATH="$ALT_PATH:$TMP/shadow-tools"
if run_timed "$UPDATE" unused update-path-scan fast 7 "$ALT_PATH" "$TMP/slow-global/bin"; then
  alternate_probes="$(wc -l < "$TMP/update-path-scan.alt.calls" 2>/dev/null || printf '0')"
  [[ "$alternate_probes" =~ ^[0-9]+$ ]] && [ "$alternate_probes" -gt 0 ] \
    && [ "$alternate_probes" -lt 32 ] \
    && pass "PATH shadow scan stops at its total budget ($alternate_probes alternate probes)" \
    || fail "PATH shadow scan did not respect its total budget ($alternate_probes probes)"
  [ ! -s "$TMP/update-path-scan.out" ] \
    && pass 'incomplete PATH scan conservatively suppresses the updater advisory' \
    || fail 'incomplete PATH scan emitted an updater advisory'
fi

if [ "$FAILURES" -gt 0 ]; then
  printf 'PASSES=%s FAILURES=%s\n' "$PASSES" "$FAILURES" >&2
  exit 1
fi
printf 'PASS: all SessionStart monitor/update budget cases passed (PASSES=%s FAILURES=%s)\n' "$PASSES" "$FAILURES"
