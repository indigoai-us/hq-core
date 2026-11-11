#!/usr/bin/env bash
# hq-core: public
# master-hook.sh and the hqd shim on the hot path:
#   1. HQ Fleet's local hook adapter has already run the registry scope check
#      for a PreToolUse, so master-hook makes no hqd call there. The skip needs
#      the adapter's variables AND the adapter as master-hook's parent process:
#      the variables alone (inherited, or set by hand) keep the call, as do a
#      process started under the adapter, HQ_HARNESS other than codex, and an
#      opt-out of the scope authorizer. Other runtimes and other adapter events
#      keep the call.
#   2. master-hook hands the shim a deadline of its own start plus the shim
#      budget (HQ_HQD_SHIM_TIMEOUT_MS, default 3000).
#   3. With the real shim and a daemon that accepts and never reads, a
#      PreToolUse with a 200 KB payload costs at most the budget plus a small
#      margin over the same call with no daemon, and the decision is the
#      no-daemon decision.
# The stub shim logs one line per call; the child hook logs the local fan-out.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="${HQ_MASTER_HOOK_TEST_HOOK:-$ROOT/.claude/hooks/master-hook.sh}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "master-hook.sh not found at $MASTER"
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl required"; exit 0; }
case "${OSTYPE:-}" in
  # hqd uses a named pipe on Windows; master-hook never routes there.
  msys*|cygwin*|win32*) echo "SKIP: no hqd Unix socket on Windows"; exit 0 ;;
esac

# Unix socket paths are capped near 104 bytes: keep the fixture under /tmp.
TMP="$(cd "$(mktemp -d /tmp/mhskip.XXXXXX)" && pwd)"
STUB_PID=""
cleanup() {
  if [ -n "$STUB_PID" ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }

make_fixture() { # <dir> <shim: stub|real>
  local fix="$1" kind="$2"
  mkdir -p "$fix/.claude/hooks" "$fix/core/hooks/PreToolUse" "$fix/core/scripts" "$fix/workspace/sessions"
  cp "$MASTER" "$fix/.claude/hooks/master-hook.sh"
  cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$ROOT/.claude/hooks/hook-gate.sh" "$fix/.claude/hooks/"
  cp "$ROOT/core/scripts/resolve-hq-root.sh" "$ROOT/core/scripts/hq-anywhere-runtime-flag.cjs" \
    "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$fix/core/scripts/"
  if [ "$kind" = real ]; then
    # The real shim behind a wrapper that logs how long the call took, so the
    # bound is checked on the hqd call itself and not on the whole machine.
    cp "$ROOT/core/scripts/hqd-hook-shim.sh" "$fix/core/scripts/hqd-hook-shim-real.sh"
    cat > "$fix/core/scripts/hqd-hook-shim.sh" <<'SHIM'
#!/bin/sh
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
/bin/sh "${0%/*}/hqd-hook-shim-real.sh" "$@"
rc=$?
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
printf '%s %s\n' "$((t1 - t0))" "$rc" >> "$HQ_TEST_SHIM_TIMES"
exit "$rc"
SHIM
  else
    cat > "$fix/core/scripts/hqd-hook-shim.sh" <<'SHIM'
#!/bin/sh
payload=$(cat)
case "$payload" in
  *'"tool_use_id":"'*) id=${payload#*'"tool_use_id":"'}; id=${id%%'"'*} ;;
  *) id=unknown ;;
esac
printf '%s %s %s\n' "$id" "${1:-}" "${HQ_HQD_SHIM_DEADLINE_MS:-none}" >> "$HQ_TEST_SHIM_LOG"
SHIM
  fi
  cat > "$fix/core/hooks/PreToolUse/50-fanout.sh" <<'HOOK'
#!/bin/bash
payload="$(cat)"
id="${payload#*\"tool_use_id\":\"}"; id="${id%%\"*}"
printf '%s\n' "${id:0:64}" >> "$HQ_TEST_FANOUT_LOG"
HOOK
  chmod +x "$fix/core/scripts/hqd-hook-shim.sh" "$fix/core/hooks/PreToolUse/50-fanout.sh"
}

FIX="$TMP/hq"
make_fixture "$FIX" stub
SHIM_LOG="$TMP/shim-calls.log"
FANOUT_LOG="$TMP/fanout.log"
: > "$SHIM_LOG"
: > "$FANOUT_LOG"
HOME_DIR="$TMP/home"
SOCK="$HOME_DIR/.hq/daemon/hqd.sock"
mkdir -p "$(dirname "$SOCK")"

# A daemon that accepts every connection and never reads from it.
perl -MIO::Socket::UNIX -e '
my $srv = IO::Socket::UNIX->new(Type => IO::Socket::UNIX::SOCK_STREAM(), Local => $ARGV[0], Listen => 16) or die "listen: $!\n";
my @held;
while (my $c = $srv->accept) { push @held, $c; }' "$SOCK" &
STUB_PID=$!
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done
[ -S "$SOCK" ] || fail "fixture hqd socket did not become ready"

# A stand-in for HQ Fleet's adapter, launched the way the fleet launches it
# (/bin/bash <profile>/hooks/hq-fleet-local-hook-adapter.sh --hq-root <root>
# --event <event>). It pipes the payload to master-hook as a direct child, as
# the real adapter's run_master_hook does. With HQ_TEST_NESTED=1 it starts an
# intermediate process instead (a session or hook started under the adapter),
# which then runs master-hook.
ADAPTER="$TMP/profile/hooks/hq-fleet-local-hook-adapter.sh"
mkdir -p "$TMP/profile/hooks"
cat > "$ADAPTER" <<'ADAPTER'
#!/bin/bash
root="$2"; ev="$5"
payload="$(cat)"
if [ "${HQ_TEST_NESTED:-}" = "1" ]; then
  printf '%s' "$payload" | bash "${0%/*}/nested-session.sh" "$root" "$ev"
else
  printf '%s' "$payload" | bash "$root/.claude/hooks/master-hook.sh" "$ev"
fi
ADAPTER
cat > "$TMP/profile/hooks/nested-session.sh" <<'NESTED'
#!/bin/bash
payload="$(cat)"
printf '%s' "$payload" | bash "$1/.claude/hooks/master-hook.sh" "$2"
NESTED
ADAPTER_ENV=(HQ_CHECKPOINT_RUNTIME=hq-fleet-local HQ_HARNESS=codex HQ_WORK_MESH_DISABLED=1)

# run_case <fixture> <event> <tool_use_id> <command> [env assignments...]
# Sets CASE_RC and CASE_MS. With CASE_VIA_ADAPTER=1, master-hook runs under
# the stand-in adapter.
CASE_VIA_ADAPTER=0
run_case() {
  local fix="$1" event="$2" id="$3" cmd="$4" t0 t1
  shift 4
  t0="$(now_ms)"
  CASE_RC=0
  # The command goes to jq on stdin: a 200 KB argument is over the Linux
  # per-argument limit. printf is a builtin, so it has no such limit.
  printf '%s' "$cmd" | jq -Rsc --arg ev "$event" --arg id "$id" \
    '{session_id:"adapter-skip-sid",hook_event_name:$ev,tool_name:"Bash",tool_input:{command:.},tool_use_id:$id,cwd:"/tmp"}' \
    > "$TMP/payload-$id" || fail "could not build the payload for $id"
  [ "$(wc -c < "$TMP/payload-$id")" -gt "${#cmd}" ] || fail "payload for $id is shorter than its command"
  local launch=(bash "$fix/.claude/hooks/master-hook.sh" "$event")
  if [ "$CASE_VIA_ADAPTER" = "1" ]; then
    launch=(/bin/bash "$ADAPTER" --hq-root "$fix" --event pre_tool_call "$event")
  fi
  (cd "$fix" && env -u HQ_HQD_SOCKET -u HQ_REGISTRY_DIR -u HQ_FLAG_HQ_ANYWHERE_RUNTIME \
        -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID -u HQ_CHECKPOINT_RUNTIME -u HQ_HQD_SHIM_TIMEOUT_MS \
        -u HQ_HARNESS -u HQ_WORK_MESH_HARNESS -u HQ_FLEET_LOCAL_HOOK_SKIP -u HQ_DISABLED_HOOKS \
        -u HQ_HOOK_PROFILE -u HQ_TEST_NESTED \
        HOME="$HOME_DIR" CLAUDE_PROJECT_DIR="$fix" HQ_HOOK_TIMEOUT_SENTRY=0 \
        HQ_TEST_SHIM_LOG="$SHIM_LOG" HQ_TEST_FANOUT_LOG="$FANOUT_LOG" "$@" \
        "${launch[@]}" <"$TMP/payload-$id" >"$TMP/stdout-$id" 2>"$TMP/stderr-$id") || CASE_RC=$?
  t1="$(now_ms)"
  CASE_MS=$((t1 - t0))
  CASE_T0="$t0"
  CASE_T1="$t1"
}
calls() { awk -v id="$1" '$1 == id' "$2" | wc -l | tr -d ' '; }

command -v jq >/dev/null 2>&1 || fail "jq required"

# 1. Adapter PreToolUse (the adapter is the parent and set its variables): no
# hqd call, local fan-out still runs.
CASE_VIA_ADAPTER=1
run_case "$FIX" PreToolUse toolu_adapter true "${ADAPTER_ENV[@]}"
CASE_VIA_ADAPTER=0
[ "$CASE_RC" -eq 0 ] || fail "adapter PreToolUse exited $CASE_RC: $(cat "$TMP/stderr-toolu_adapter")"
[ "$(calls toolu_adapter "$SHIM_LOG")" = "0" ] || fail "adapter PreToolUse called the hqd shim"
[ "$(calls toolu_adapter "$FANOUT_LOG")" = "1" ] || fail "adapter PreToolUse skipped the local fan-out"
pass "HQ Fleet adapter PreToolUse makes no hqd call and keeps the local fan-out"

# 1b. The adapter's variables alone, inherited or set by hand, with some other
# process as master-hook's parent: the hqd call stays.
run_case "$FIX" PreToolUse toolu_env_only true "${ADAPTER_ENV[@]}"
[ "$(calls toolu_env_only "$SHIM_LOG")" = "1" ] \
  || fail "the adapter's variables alone switched off the hqd call (parent was not the adapter)"
pass "the adapter's variables alone keep the hqd call"

# 1c. A process started under the adapter (a session or hook that inherited
# its environment) that runs master-hook: the hqd call stays.
CASE_VIA_ADAPTER=1
run_case "$FIX" PreToolUse toolu_nested true "${ADAPTER_ENV[@]}" HQ_TEST_NESTED=1
CASE_VIA_ADAPTER=0
[ "$(calls toolu_nested "$FANOUT_LOG")" = "1" ] || fail "nested run did not reach master-hook"
[ "$(calls toolu_nested "$SHIM_LOG")" = "1" ] \
  || fail "a process started under the adapter lost the hqd call"
pass "a process started under the adapter keeps the hqd call"

# 1d. Under the adapter, but HQ_HARNESS is not codex (master-hook then runs
# the registry itself) or the scope authorizer is opted out: the call stays.
CASE_VIA_ADAPTER=1
run_case "$FIX" PreToolUse toolu_no_harness true HQ_CHECKPOINT_RUNTIME=hq-fleet-local
run_case "$FIX" PreToolUse toolu_fleet_skip true "${ADAPTER_ENV[@]}" HQ_FLEET_LOCAL_HOOK_SKIP=foo,mandatory-scope-authorizer
run_case "$FIX" PreToolUse toolu_disabled true "${ADAPTER_ENV[@]}" HQ_DISABLED_HOOKS="detect-secrets, mandatory-scope-authorizer"
# hook-gate.sh strips quotes from HQ_DISABLED_HOOKS entries, so a quoted entry
# also switches the authorizer off and must also keep the call.
run_case "$FIX" PreToolUse toolu_disabled_quoted true "${ADAPTER_ENV[@]}" HQ_DISABLED_HOOKS='"mandatory-scope-authorizer"'
CASE_VIA_ADAPTER=0
[ "$(calls toolu_disabled_quoted "$SHIM_LOG")" = "1" ] \
  || fail "a quoted HQ_DISABLED_HOOKS entry for the scope authorizer lost the hqd call"
[ "$(calls toolu_no_harness "$SHIM_LOG")" = "1" ] || fail "adapter without HQ_HARNESS=codex lost the hqd call"
[ "$(calls toolu_fleet_skip "$SHIM_LOG")" = "1" ] \
  || fail "HQ_FLEET_LOCAL_HOOK_SKIP naming the scope authorizer lost the hqd call"
[ "$(calls toolu_disabled "$SHIM_LOG")" = "1" ] \
  || fail "HQ_DISABLED_HOOKS naming the scope authorizer lost the hqd call"
pass "adapter without HQ_HARNESS=codex, or with the scope authorizer opted out, keeps the hqd call"

# 2. Controls: without the adapter signal, or with another runtime, the call stays.
run_case "$FIX" PreToolUse toolu_claude true
[ "$(calls toolu_claude "$SHIM_LOG")" = "1" ] || fail "Claude PreToolUse did not call the hqd shim"
run_case "$FIX" PreToolUse toolu_codex true HQ_CHECKPOINT_RUNTIME=codex
[ "$(calls toolu_codex "$SHIM_LOG")" = "1" ] || fail "codex-runtime PreToolUse did not call the hqd shim"
pass "other runtimes keep the hqd call"

# 3. Adapter events other than PreToolUse keep the call (no registry check to repeat).
CASE_VIA_ADAPTER=1
run_case "$FIX" PostToolUse toolu_adapter_post true "${ADAPTER_ENV[@]}"
CASE_VIA_ADAPTER=0
[ "$(calls toolu_adapter_post "$SHIM_LOG")" = "1" ] || fail "adapter PostToolUse lost its hqd call"
pass "adapter PostToolUse keeps the hqd call"

# 4. Deadline handed to the shim: master-hook start + budget.
run_case "$FIX" PreToolUse toolu_deadline true
dl="$(awk '$1 == "toolu_deadline" {print $3}' "$SHIM_LOG")"
[[ "$dl" =~ ^[0-9]{13}$ ]] || fail "shim got no epoch-ms deadline (got '$dl')"
[ "$dl" -ge $((CASE_T0 + 3000)) ] && [ "$dl" -le $((CASE_T1 + 3000)) ] \
  || fail "default deadline $dl is not start+3000 (run $CASE_T0..$CASE_T1)"
run_case "$FIX" PreToolUse toolu_deadline_500 true HQ_HQD_SHIM_TIMEOUT_MS=500
dl="$(awk '$1 == "toolu_deadline_500" {print $3}' "$SHIM_LOG")"
[ "$dl" -ge $((CASE_T0 + 500)) ] && [ "$dl" -le $((CASE_T1 + 500)) ] \
  || fail "HQ_HQD_SHIM_TIMEOUT_MS=500 deadline $dl is not start+500 (run $CASE_T0..$CASE_T1)"
run_case "$FIX" PreToolUse toolu_deadline_zero true HQ_HQD_SHIM_TIMEOUT_MS=000
dl="$(awk '$1 == "toolu_deadline_zero" {print $3}' "$SHIM_LOG")"
[ "$dl" -ge $((CASE_T0 + 3000)) ] && [ "$dl" -le $((CASE_T1 + 3000)) ] \
  || fail "HQ_HQD_SHIM_TIMEOUT_MS=000 must mean the 3000 default (deadline $dl)"
pass "master-hook passes its start + budget as the shim deadline"

# 5. Real shim, daemon that never reads, 200 KB payload (larger than the
# macOS socket send buffer; core/scripts/hqd-hook-shim.test.sh covers Linux). The hqd call returns within the budget plus the
# 250 ms hard-timer grace and a start-up margin, reports 75, and master-hook
# gives the decision of the same call with no daemon.
RFIX="$TMP/hq-real"
make_fixture "$RFIX" real
SHIM_TIMES="$TMP/shim-times.log"
: > "$SHIM_TIMES"
BIG="echo $(perl -e 'print "x" x 200000')"
NOSOCK_HOME="$TMP/home-nosock"
mkdir -p "$NOSOCK_HOME"
run_case "$RFIX" PreToolUse toolu_base "$BIG" HOME="$NOSOCK_HOME" HQ_TEST_SHIM_TIMES="$SHIM_TIMES"
base_rc="$CASE_RC"
base_out="$(cat "$TMP/stdout-toolu_base")"
[ ! -s "$SHIM_TIMES" ] || fail "no-daemon run called the shim"
run_case "$RFIX" PreToolUse toolu_blocked "$BIG" HQ_HQD_SHIM_TIMEOUT_MS=1000 HQ_TEST_SHIM_TIMES="$SHIM_TIMES"
[ "$CASE_RC" = "$base_rc" ] || fail "blocked daemon changed the decision: rc $CASE_RC, no-daemon rc $base_rc"
[ "$(cat "$TMP/stdout-toolu_blocked")" = "$base_out" ] || fail "blocked daemon changed the hook output"
read -r shim_ms shim_rc < "$SHIM_TIMES" || fail "blocked run did not call the shim"
[ "$shim_rc" = "75" ] || fail "blocked daemon: shim exited $shim_rc, want 75 (fall back to the direct path)"
[ "$shim_ms" -le 3500 ] || fail "blocked daemon: hqd call took ${shim_ms} ms (budget 1000 ms + 2500 ms start-up margin)"
pass "blocked daemon: hqd call bounded (${shim_ms} ms for a 1000 ms budget), decision unchanged"

# Without the fix this call never returned: a timed retry doubled the budget,
# and a write blocked after a partial send outlived the alarm.
run_case "$RFIX" PreToolUse toolu_blocked_default "$BIG" HQ_TEST_SHIM_TIMES="$SHIM_TIMES"
[ "$CASE_RC" = "$base_rc" ] || fail "blocked daemon (default budget) changed the decision"
shim_ms="$(awk 'NR == 2 {print $1}' "$SHIM_TIMES")"
[ "$shim_ms" -le 5500 ] || fail "blocked daemon: default-budget hqd call took ${shim_ms} ms (3000 ms + 2500 ms start-up margin)"
pass "blocked daemon, default budget: hqd call bounded (${shim_ms} ms)"

echo "ALL PASS: master-hook-hqd-adapter-skip"
