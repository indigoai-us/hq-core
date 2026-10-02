#!/usr/bin/env bash
# hq-core: public
# master-hook.sh registered at user scope AND project scope fires twice per
# event with the same payload (tests/fixtures/runtime/*-user-hook-input.json).
# The dispatcher must run its child hooks once per session_id + event +
# tool_use_id. A child hook here appends one policy-trigger ledger line per
# run, so the ledger line count is the dispatch count.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
FIXTURES="$ROOT/tests/fixtures/runtime"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
for f in claude-user-hook-input.json codex-user-hook-input.json; do
  [ -f "$FIXTURES/$f" ] || fail "missing fixture $f"
done

TMP="$(mktemp -d)"
cleanup() {
  if [ -n "${SOCKET_PID:-}" ]; then
    kill "$SOCKET_PID" 2>/dev/null || true
    wait "$SOCKET_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/hooks/PreToolUse" "$FIX/core/hooks/SessionStart" \
  "$FIX/core/hooks/Stop" "$FIX/core/scripts" "$FIX/workspace/sessions"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIX/.claude/hooks/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$ROOT/core/scripts/hq-anywhere-runtime-flag.cjs" \
  "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$FIX/core/scripts/"
source "$ROOT/core/scripts/tests/hq-anywhere-flag-fixture.sh"
hq_anywhere_flag_fixture "$TMP/fake-cli"
LEDGER="$FIX/workspace/orchestrator/policy-trigger-state/ledger.jsonl"
for ev in PreToolUse SessionStart Stop; do
  cat > "$FIX/core/hooks/$ev/50-ledger.sh" <<'HOOK'
#!/bin/bash
payload="$(cat)"
root="$(cd "$(dirname "$0")/../../.." && pwd)"
mkdir -p "$root/workspace/orchestrator/policy-trigger-state"
printf '%s' "$payload" | jq -c --arg ev "$HQ_HOOK_EVENT" \
  '{event:$ev, session_id, tool_use_id:(.tool_use_id // null)}' \
  >> "$root/workspace/orchestrator/policy-trigger-state/ledger.jsonl"
HOOK
  chmod +x "$FIX/core/hooks/$ev/50-ledger.sh"
done

# User scope: absolute path, launched with PWD inside the HQ root.
# Project scope: $CLAUDE_PROJECT_DIR form. Both run at the same time.
dispatch_pair_seq=0
dispatch_pair() {
  local event="$1" payload="$2" pair_dir user_pid project_pid
  shift 2
  dispatch_pair_seq=$((dispatch_pair_seq + 1))
  pair_dir="$TMP/dispatch-pair-$dispatch_pair_seq"
  mkdir -p "$pair_dir"
  # Hold both registrations at the same start barrier. Without this, a busy
  # runner can delay one background shell past the no-tool-id dedupe window,
  # turning one logical event into two valid dispatches.
  ( touch "$pair_dir/user-ready"; while [ ! -e "$pair_dir/go" ]; do sleep 0.01; done
    cd "$FIX" && printf '%s' "$payload" | env HQ_HOOK_TIMEOUT_SENTRY=0 HQ_CLI_BIN="$TMP/fake-cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG=true "$@" \
      bash "$FIX/.claude/hooks/master-hook.sh" "$event" >/dev/null 2>&1 ) & user_pid=$!
  ( touch "$pair_dir/project-ready"; while [ ! -e "$pair_dir/go" ]; do sleep 0.01; done
    cd "$FIX" && printf '%s' "$payload" | env HQ_HOOK_TIMEOUT_SENTRY=0 CLAUDE_PROJECT_DIR="$FIX" HQ_CLI_BIN="$TMP/fake-cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG=true "$@" \
      bash "$FIX/.claude/hooks/master-hook.sh" "$event" >/dev/null 2>&1 ) & project_pid=$!
  while [ ! -e "$pair_dir/user-ready" ] || [ ! -e "$pair_dir/project-ready" ]; do sleep 0.01; done
  touch "$pair_dir/go"
  wait "$user_pid"
  wait "$project_pid"
}
count() { [ -f "$LEDGER" ] || { echo 0; return; }; jq -s --arg q "$1" '[.[] | select(.tool_use_id == $q)] | length' "$LEDGER"; }
count_event() { [ -f "$LEDGER" ] || { echo 0; return; }; jq -s --arg e "$1" --arg s "$2" '[.[] | select(.event == $e and .session_id == $s)] | length' "$LEDGER"; }

# 1. Claude PreToolUse pair (fixture) → exactly one ledger entry.
CL_PRE="$(jq -c '.PreToolUse.user_scope' "$FIXTURES/claude-user-hook-input.json")"
CL_TID="$(printf '%s' "$CL_PRE" | jq -r .tool_use_id)"
CL_SID="$(printf '%s' "$CL_PRE" | jq -r .session_id)"
dispatch_pair PreToolUse "$CL_PRE"
n="$(count "$CL_TID")"; [ "$n" = "1" ] || fail "claude PreToolUse pair wrote $n ledger entries, want 1"
[ -d "$FIX/workspace/sessions/$CL_SID/dispatch-locks" ] || fail "no lock dir under workspace/sessions/<sid>/"
pass "claude user+project PreToolUse dispatches once"

# 1a. The in-root project hook routes through the hqd shim only while the
# runtime flag is on and the daemon socket exists. The CLI companion's global
# root guard leaves the project registration as the one active path.
ROUTING_HOME="$TMP/routing-home"
ROUTING_SOCKET="$ROUTING_HOME/.hq/hqd.sock"
SHIM_LEDGER="$TMP/shim-ledger.jsonl"
SHIM_CALLS="$TMP/shim-calls.log"
mkdir -p "$(dirname "$ROUTING_SOCKET")"
cat > "$FIX/core/scripts/hqd-hook-shim.sh" <<'SHIM'
#!/bin/sh
payload=$(cat)
printf '%s\n' "$1" >> "$HQ_TEST_SHIM_CALLS"
[ "${HQ_TEST_SHIM_UNREACHABLE:-false}" != true ] || exit 75
printf '%s\n' "$payload" >> "$HQ_TEST_SHIM_LEDGER"
SHIM
chmod +x "$FIX/core/scripts/hqd-hook-shim.sh"
node -e 'const net=require("node:net"); const s=net.createServer(); s.listen(process.argv[1], () => process.stdout.write("ready\n")); process.on("SIGTERM", () => s.close(() => process.exit(0)));' "$ROUTING_SOCKET" >"$TMP/socket-ready" 2>&1 &
SOCKET_PID=$!
for _ in $(seq 1 100); do [ -S "$ROUTING_SOCKET" ] && break; sleep 0.01; done
[ -S "$ROUTING_SOCKET" ] || fail "fixture hqd socket did not become ready"

ROUTE_ON="$(printf '%s' "$CL_PRE" | jq -c '.tool_use_id = "toolu_route_on"')"
printf '%s' "$ROUTE_ON" | (cd "$FIX" && env HOME="$ROUTING_HOME" HQ_TEST_SHIM_LEDGER="$SHIM_LEDGER" HQ_TEST_SHIM_CALLS="$SHIM_CALLS" CLAUDE_PROJECT_DIR="$FIX" HQ_CLI_BIN="$TMP/fake-cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG=true HQ_HOOK_TIMEOUT_SENTRY=0 bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse >/dev/null 2>&1)
[ "$(jq -s --arg q toolu_route_on '[.[] | select(.tool_use_id == $q)] | length' "$SHIM_LEDGER")" = "1" ] || fail "flag-on in-root hook did not route once through shim"
[ "$(jq -s --arg q toolu_route_on '[.[] | select(.tool_use_id == $q)] | length' "$LEDGER")" = "1" ] || fail "flag-on in-root hook skipped local master fan-out"
pass "flag on plus hqd running routes through shim once and preserves local fan-out"

ROUTE_STOPPED="$(printf '%s' "$CL_PRE" | jq -c '.tool_use_id = "toolu_route_stopped"')"
printf '%s' "$ROUTE_STOPPED" | (cd "$FIX" && env HOME="$ROUTING_HOME" HQ_HQD_SOCKET="$TMP/missing.sock" HQ_TEST_SHIM_LEDGER="$SHIM_LEDGER" HQ_TEST_SHIM_CALLS="$SHIM_CALLS" CLAUDE_PROJECT_DIR="$FIX" HQ_CLI_BIN="$TMP/fake-cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG=true HQ_HOOK_TIMEOUT_SENTRY=0 bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse >/dev/null 2>&1)
[ "$(jq -s --arg q toolu_route_stopped '[.[] | select(.tool_use_id == $q)] | length' "$LEDGER")" = "1" ] || fail "stopped-daemon in-root hook did not use direct dispatch"
pass "hqd stopped keeps in-root hook on direct master dispatch"

STALE_SOCKET="$TMP/stale.sock"
node -e 'const {spawn}=require("node:child_process"); const child=spawn(process.execPath,["-e","const net=require(\"node:net\"); const s=net.createServer(); s.listen(process.argv[1], () => process.stdout.write(\"ready\"));",process.argv[1]],{stdio:["ignore","pipe","ignore"]}); child.stdout.once("data",()=>child.kill("SIGKILL")); child.once("exit",()=>process.exit(0));' "$STALE_SOCKET" >/dev/null 2>&1
[ -S "$STALE_SOCKET" ] || fail "fixture stale Unix socket was not left behind"
ROUTE_STALE="$(printf '%s' "$CL_PRE" | jq -c '.tool_use_id = "toolu_route_stale"')"
printf '%s' "$ROUTE_STALE" | (cd "$FIX" && env HOME="$ROUTING_HOME" HQ_HQD_SOCKET="$STALE_SOCKET" HQ_TEST_SHIM_LEDGER="$SHIM_LEDGER" HQ_TEST_SHIM_CALLS="$SHIM_CALLS" HQ_TEST_SHIM_UNREACHABLE=true CLAUDE_PROJECT_DIR="$FIX" HQ_CLI_BIN="$TMP/fake-cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG=true HQ_HOOK_TIMEOUT_SENTRY=0 bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse >/dev/null 2>&1)
[ "$(jq -s --arg q toolu_route_stale '[.[] | select(.tool_use_id == $q)] | length' "$LEDGER")" = "1" ] || fail "stale-daemon socket did not fall back to direct dispatch"
[ "$(jq -s --arg q toolu_route_stale '[.[] | select(.tool_use_id == $q)] | length' "$SHIM_LEDGER")" = "0" ] || fail "stale-daemon socket reached hqd dispatch"
pass "stale hqd socket falls back to direct master dispatch"

ROUTE_FLAG_OFF="$(printf '%s' "$CL_PRE" | jq -c '.tool_use_id = "toolu_route_flag_off"')"
printf '%s' "$ROUTE_FLAG_OFF" | (cd "$FIX" && env HOME="$ROUTING_HOME" HQ_HQD_SOCKET="$ROUTING_SOCKET" HQ_TEST_SHIM_LEDGER="$SHIM_LEDGER" HQ_TEST_SHIM_CALLS="$SHIM_CALLS" CLAUDE_PROJECT_DIR="$FIX" HQ_CLI_BIN="$TMP/fake-cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG=false HQ_HOOK_TIMEOUT_SENTRY=0 bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse >/dev/null 2>&1)
[ "$(jq -s --arg q toolu_route_flag_off '[.[] | select(.tool_use_id == $q)] | length' "$LEDGER")" = "1" ] || fail "flag-off in-root hook did not use direct dispatch"
[ "$(jq -s --arg q toolu_route_flag_off '[.[] | select(.tool_use_id == $q)] | length' "$SHIM_LEDGER")" = "0" ] || fail "flag-off in-root hook reached shim"
pass "flag off keeps in-root hook on direct master dispatch"

GLOBAL_AND_PROJECT="$(printf '%s' "$CL_PRE" | jq -c '.tool_use_id = "toolu_global_project"')"
# Keep this command byte-for-byte aligned with hq-cli's hookCommand() output
# for this fixture path and the PreToolUse event.
GLOBAL_HOOK_COMMAND="if [ -d \"\${CLAUDE_PROJECT_DIR:-}\" ] && [ \"\${CLAUDE_PROJECT_DIR}\" -ef '$FIX' ]; then exit 0; fi; exec /bin/sh '$FIX/core/scripts/hqd-hook-shim.sh' 'PreToolUse' --runtime claude"
printf '%s' "$GLOBAL_AND_PROJECT" | (cd "$FIX" && env CLAUDE_PROJECT_DIR="$FIX" sh -c "$GLOBAL_HOOK_COMMAND" >/dev/null 2>&1)
printf '%s' "$GLOBAL_AND_PROJECT" | (cd "$FIX" && env HOME="$ROUTING_HOME" HQ_TEST_SHIM_LEDGER="$SHIM_LEDGER" HQ_TEST_SHIM_CALLS="$SHIM_CALLS" CLAUDE_PROJECT_DIR="$FIX" HQ_CLI_BIN="$TMP/fake-cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG=true HQ_HOOK_TIMEOUT_SENTRY=0 bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse >/dev/null 2>&1)
[ "$(jq -s --arg q toolu_global_project '[.[] | select(.tool_use_id == $q)] | length' "$SHIM_LEDGER")" = "1" ] || fail "global+project in-root registrations did not dispatch once"
[ "$(jq -s --arg q toolu_global_project '[.[] | select(.tool_use_id == $q)] | length' "$LEDGER")" = "1" ] || fail "project master fan-out did not run once with the global registration present"
pass "global root skip leaves one hqd call and one project master fan-out"
kill "$SOCKET_PID"
wait "$SOCKET_PID" 2>/dev/null || true
unset SOCKET_PID

# 2. Codex PreToolUse pair (fixture) → exactly one.
CX_PRE="$(jq -c '.PreToolUse' "$FIXTURES/codex-user-hook-input.json")"
CX_TID="$(printf '%s' "$CX_PRE" | jq -r .tool_use_id)"
dispatch_pair PreToolUse "$CX_PRE"
n="$(count "$CX_TID")"; [ "$n" = "1" ] || fail "codex PreToolUse pair wrote $n ledger entries, want 1"
pass "codex double PreToolUse dispatches once"

# 3. A new tool_use_id in the same session still dispatches.
NEXT="$(printf '%s' "$CL_PRE" | jq -c '.tool_use_id = "toolu_next"')"
dispatch_pair PreToolUse "$NEXT"
n="$(count toolu_next)"; [ "$n" = "1" ] || fail "second tool call wrote $n entries, want 1"
pass "distinct tool_use_id dispatches"

# 4. SessionStart pair (no tool_use_id) → one; Stop repeated after the window → dispatches again.
CL_SS="$(jq -c '.SessionStart.user_scope' "$FIXTURES/claude-user-hook-input.json")"
SS_SID="$(printf '%s' "$CL_SS" | jq -r .session_id)"
dispatch_pair SessionStart "$CL_SS"
n="$(count_event SessionStart "$SS_SID")"; [ "$n" = "1" ] || fail "SessionStart pair wrote $n entries, want 1"
pass "SessionStart pair dispatches once"
STOP="$(jq -nc --arg s "$SS_SID" '{session_id:$s,hook_event_name:"Stop"}')"
dispatch_pair Stop "$STOP" HQ_HOOK_DEDUPE_WINDOW=5
n="$(count_event Stop "$SS_SID")"; [ "$n" = "1" ] || fail "first Stop pair wrote $n ledger entries, want 1"
sleep 6
dispatch_pair Stop "$STOP" HQ_HOOK_DEDUPE_WINDOW=5
n="$(count_event Stop "$SS_SID")"
[ "$n" = "2" ] || {
  printf 'Stop ledger entries: %s\n' "$(jq -cs --arg s "$SS_SID" '[.[] | select(.event == "Stop" and .session_id == $s)]' "$LEDGER")" >&2
  find "$FIX/workspace/sessions/$SS_SID/dispatch-locks" -type f -maxdepth 1 -print >&2
  fail "two Stop turns wrote $n entries, want 2"
}
pass "identical non-tool event outside the window dispatches again"

# 5. HQ_HOOK_DEDUPE=0 restores raw double dispatch (proves the guard is what dedupes).
RAW="$(printf '%s' "$CL_PRE" | jq -c '.tool_use_id = "toolu_raw"')"
dispatch_pair PreToolUse "$RAW" HQ_HOOK_DEDUPE=0
n="$(count toolu_raw)"; [ "$n" = "2" ] || fail "dedupe off wrote $n entries, want 2"
pass "HQ_HOOK_DEDUPE=0 disables the guard"

# 5a. The feature flag itself is default-off; without it both registrations run.
RAW_FLAG_OFF="$(printf '%s' "$CL_PRE" | jq -c '.tool_use_id = "toolu_flag_off"')"
dispatch_pair PreToolUse "$RAW_FLAG_OFF" HQ_TEST_FLAG=false
n="$(count toolu_flag_off)"; [ "$n" = "2" ] || fail "flag-off pair wrote $n entries, want 2"
pass "hq-anywhere-runtime off preserves double dispatch"

# 5b. A nested tool_input.tool_use_id must never be used as the event dedupe key.
NESTED_ONE='{"session_id":"nested-sid","tool_input":{"tool_use_id":"inner-shared"},"tool_use_id":"toolu_top_one","hook_event_name":"PreToolUse"}'
NESTED_TWO='{"session_id":"nested-sid","tool_input":{"tool_use_id":"inner-shared"},"tool_use_id":"toolu_top_two","hook_event_name":"PreToolUse"}'
dispatch_pair PreToolUse "$NESTED_ONE"
dispatch_pair PreToolUse "$NESTED_TWO"
[ "$(count toolu_top_one)" = "1" ] || fail "first top-level ID did not dispatch once"
[ "$(count toolu_top_two)" = "1" ] || fail "second top-level ID did not dispatch once"
pass "dedupe uses the top-level tool_use_id"

# 5c. Missing flag configuration must avoid starting Node on every hook fire.
REAL_NODE="$(command -v node)"
mkdir -p "$TMP/no-config-bin"
cat > "$TMP/no-config-bin/node" <<'NODE'
#!/usr/bin/env bash
: > "${HQ_TEST_NODE_CALLED:?}"
exec "${HQ_TEST_REAL_NODE:?}" "$@"
NODE
chmod +x "$TMP/no-config-bin/node"
NO_CONFIG="$(printf '%s' "$CL_PRE" | jq -c '.tool_use_id = "toolu_no_flag_config"')"
dispatch_pair PreToolUse "$NO_CONFIG" HQ_FLAGS_API_URL= HQ_COMPANY_UID= \
  PATH="$TMP/no-config-bin:$PATH" HQ_TEST_REAL_NODE="$REAL_NODE" HQ_TEST_NODE_CALLED="$TMP/node-called"
[ ! -e "$TMP/node-called" ] || fail "master spawned Node without flag configuration"
pass "missing flag configuration avoids the Node startup cost"

# 5d. A deduped blocking event still blocks. A child hook exits 2 on BLOCKME;
# both concurrent twins and a sequential replay without a tool_use_id must
# return 2, never a silent 0.
cat > "$FIX/core/hooks/PreToolUse/40-blockme.sh" <<'HOOK'
#!/bin/bash
grep -q BLOCKME && { echo "blocked BLOCKME" >&2; exit 2; }
exit 0
HOOK
chmod +x "$FIX/core/hooks/PreToolUse/40-blockme.sh"
BLOCK_TID="$(printf '%s' "$CL_PRE" | jq -c '.tool_use_id = "toolu_block" | .tool_input = {command:"BLOCKME"}')"
rc_a=0; rc_b=0
( cd "$FIX" && printf '%s' "$BLOCK_TID" | HQ_HOOK_TIMEOUT_SENTRY=0 bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse >/dev/null 2>&1 ) & pid_a=$!
( cd "$FIX" && printf '%s' "$BLOCK_TID" | HQ_HOOK_TIMEOUT_SENTRY=0 CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse >/dev/null 2>&1 ) & pid_b=$!
wait "$pid_a" || rc_a=$?
wait "$pid_b" || rc_b=$?
[ "$rc_a" = "2" ] && [ "$rc_b" = "2" ] || fail "concurrent blocking twins returned $rc_a/$rc_b, want 2/2"
BLOCK_HASH="$(printf '%s' "$CL_PRE" | jq -c 'del(.tool_use_id) | .tool_input = {command:"BLOCKME"}')"
for attempt in 1 2; do
  rc=0
  ( cd "$FIX" && printf '%s' "$BLOCK_HASH" | HQ_HOOK_TIMEOUT_SENTRY=0 bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse >/dev/null 2>&1 ) || rc=$?
  [ "$rc" = "2" ] || fail "sequential blocking replay $attempt returned $rc, want 2"
done
rm -f "$FIX/core/hooks/PreToolUse/40-blockme.sh"
pass "deduped blocking event still blocks"

# 6. The contracts validator fails on a relative hook path and on missing dedupe.
VAL="$ROOT/core/scripts/validate-agent-runtime-contracts.mjs"
if command -v node >/dev/null 2>&1; then
  V="$TMP/val"
  mkdir -p "$V/.claude/hooks"
  cp "$MASTER" "$V/.claude/hooks/master-hook.sh"
  # shellcheck disable=SC2016 # the literal $CLAUDE_PROJECT_DIR is the registration text
  printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/master-hook.sh\" PreToolUse"}]}]}}' \
    > "$V/.claude/settings.json"
  node "$VAL" validate-hooks --root "$V" >/dev/null 2>&1 || fail "validator rejected an anchored registration"
  printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash .claude/hooks/master-hook.sh PreToolUse"}]}]}}' \
    > "$V/.claude/settings.json"
  if node "$VAL" validate-hooks --root "$V" >/dev/null 2>&1; then fail "validator accepted a relative hook path"; fi
  pass "validator rejects a relative hook registration path"
  printf '%s' '{"hooks":{}}' > "$V/.claude/settings.json"
  grep -v 'dispatch-locks' "$MASTER" > "$V/.claude/hooks/master-hook.sh"
  if node "$VAL" validate-hooks --root "$V" >/dev/null 2>&1; then fail "validator accepted master-hook without dedupe"; fi
  pass "validator rejects master-hook without dispatch dedupe"
else
  echo "  skip: node not installed; validator cases not run"
fi

echo "ALL PASS: master-hook-double-dispatch"
