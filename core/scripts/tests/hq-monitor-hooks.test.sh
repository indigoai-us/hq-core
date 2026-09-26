#!/usr/bin/env bash
# Regression coverage for the gated guard, delivery wrappers, and shared hooks.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
GUARD="$ROOT/.claude/hooks/hq-monitor-guard.sh"
SESSION="$ROOT/.claude/hooks/hq-monitor-session-hook.sh"
START="$ROOT/.claude/hooks/hq-monitor-session-start.sh"
SETTINGS="$ROOT/.claude/settings.json"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
ADAPTER_CORE="$ROOT/core/scripts/lib/hook-adapter-core.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-monitor-hooks.XXXXXX")"
TMP_ROOT="$TMP/hq"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

for tool in jq node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: missing $tool" >&2; exit 1; }
done

# Minimal root keeps test session markers and hook logs out of the checkout.
mkdir -p "$TMP_ROOT/.claude/hooks" "$TMP_ROOT/.codex/hooks" "$TMP_ROOT/.grok/hooks" "$TMP_ROOT/core/scripts/lib" "$TMP_ROOT/workspace"
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP_ROOT/core/scripts/hook-lib.sh"
cp "$SETTINGS" "$TMP_ROOT/.claude/settings.json"
cp "$REGISTRY" "$TMP_ROOT/.claude/hooks/hook-registry.json"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$TMP_ROOT/.claude/hooks/hook-gate.sh"
cp "$ROOT/.claude/hooks/hq-monitor-hook-lib.sh" "$TMP_ROOT/.claude/hooks/hq-monitor-hook-lib.sh"
cp "$GUARD" "$TMP_ROOT/.claude/hooks/hq-monitor-guard.sh"
cp "$SESSION" "$TMP_ROOT/.claude/hooks/hq-monitor-session-hook.sh"
cp "$START" "$TMP_ROOT/.claude/hooks/hq-monitor-session-start.sh"
cp "$ADAPTER_CORE" "$TMP_ROOT/core/scripts/lib/hook-adapter-core.sh"
cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$TMP_ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
cp "$ROOT/.grok/hooks/hq-grok-hook-adapter.sh" "$TMP_ROOT/.grok/hooks/hq-grok-hook-adapter.sh"

CLI="$TMP/npm-global/lib/node_modules/@indigoai-us/hq-cli"
mkdir -p "$CLI/bin" "$TMP/bin"
cat > "$CLI/package.json" <<'JSON'
{"name":"@indigoai-us/hq-cli","bin":{"hq":"bin/hq"}}
JSON
cat > "$CLI/bin/hq" <<'SH'
#!/bin/bash
exec "$HQ_TEST_HQ_BIN" "$@"
SH
chmod +x "$CLI/bin/hq"
ln -s "$CLI/bin/hq" "$TMP/bin/hq"

HQ_LOG="$TMP/hq-calls.log"
HQ_INPUT="$TMP/hq-input.json"
cat > "$TMP/fake-hq.sh" <<'SH'
#!/bin/bash
if [ "${HQ_NO_UPDATE_CHECK:-}" != 1 ]; then
  printf 'test failure: hook invoked hq without disabling self-update\n' >&2
  exit 98
fi
if [ -n "${HQ_TEST_HQ_MARKER:-}" ]; then printf '%s\n' "$*" >> "$HQ_TEST_HQ_MARKER"; fi
if [ "${1:-}" = "--help" ]; then
  if [ "${HQ_TEST_NO_MONITOR:-false}" = true ]; then
    printf 'Usage: hq [command]\nCommands:\n  status\n'
  else
    printf 'Usage: hq [command]\nCommands:\n  monitor [options]  Monitor session events\n'
  fi
  exit 0
fi
if [ "${1:-}" = "monitor" ] && [ "${2:-}" = "enabled" ]; then
  if [ -n "${HQ_TEST_MONITOR_ENABLED_CALL_MARKER:-}" ]; then printf 'called\n' >> "$HQ_TEST_MONITOR_ENABLED_CALL_MARKER"; fi
  [ "${HQ_TEST_NO_MONITOR:-false}" = true ] && exit 1
  [ "${HQ_TEST_MONITOR_ENABLED:-false}" = true ] && exit 0 || exit 1
fi
if [ "${1:-}" = monitor ]; then
  [ "${HQ_TEST_MONITOR_ENABLED:-false}" = true ] || exit 0
  cat > "$HQ_TEST_HQ_INPUT"
  if [ "${2:-}" = wait ]; then printf '{"wake":true}\n'; exit 2; fi
  if [ -n "${HQ_TEST_DRAIN_CONTEXT:-}" ]; then
    jq -nc --arg event "${6:-PreToolUse}" --arg c "$HQ_TEST_DRAIN_CONTEXT" '{hookSpecificOutput:{hookEventName:$event,additionalContext:$c}}'
    exit 0
  fi
  printf '{"drained":true}\n'
fi
SH
chmod +x "$TMP/fake-hq.sh"

base_env=(PATH="$TMP/bin:$PATH" HQ_ROOT="$TMP_ROOT" CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_CLI_BIN="$TMP/bin/hq" HQ_TEST_HQ_BIN="$TMP/fake-hq.sh" HQ_TEST_HQ_MARKER="$HQ_LOG" HQ_TEST_HQ_INPUT="$HQ_INPUT")

payload() {
  local runtime="$1" command_text="$2" background="${3:-false}" sid="${4:-monitor-session}"
  case "$runtime" in
    grok) jq -nc --arg root "$TMP_ROOT" --arg sid "$sid" --arg command "$command_text" --argjson bg "$background" '{hookEventName:"PreToolUse",toolName:"Shell",cwd:$root,session_id:$sid,toolInput:{command:$command,run_in_background:$bg},tool_input:{command:$command,run_in_background:$bg}}' ;;
    *) jq -nc --arg root "$TMP_ROOT" --arg sid "$sid" --arg command "$command_text" --argjson bg "$background" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,session_id:$sid,tool_input:{command:$command,run_in_background:$bg}}' ;;
  esac
}

run_guard() {
  local runtime="$1" command_text="$2" background="${3:-false}" lane="${4:-}" enabled="${5:-true}" sid="${6:-monitor-session}" rc=0
  local lane_env=()
  [ -n "$lane" ] && lane_env+=(HQ_LANE_ID="$lane")
  payload "$runtime" "$command_text" "$background" "$sid" \
    | env "${base_env[@]}" HQ_CHECKPOINT_RUNTIME="$runtime" HQ_TEST_MONITOR_ENABLED="$enabled" \
        HQ_TEST_MONITOR_ENABLED_CALL_MARKER="$TMP/flag-calls.log" ${lane_env[@]+"${lane_env[@]}"} \
        bash "$GUARD" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  printf '%s' "$rc"
}

expect_block() {
  local runtime="$1" command_text="$2" label="$3" rc
  rc="$(run_guard "$runtime" "$command_text")"
  if [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | startswith("Blocked: ") and endswith("Do not chain shorter sleeps to work around this block."))' "$TMP/stdout" >/dev/null; then ok "$label blocks"; else bad "$label blocks (rc=$rc stdout=$(cat "$TMP/stdout"))"; fi
}

expect_allow() {
  local runtime="$1" command_text="$2" label="$3" background="${4:-false}" lane="${5:-}" enabled="${6:-true}" rc
  rc="$(run_guard "$runtime" "$command_text" "$background" "$lane" "$enabled")"
  if [ "$rc" = 0 ] && ! jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null 2>&1; then ok "$label allows"; else bad "$label allows (rc=$rc stdout=$(cat "$TMP/stdout"))"; fi
}

echo '[1] guard blocks the requested foreground waits in each runtime'
for runtime in claude codex grok; do
  expect_block "$runtime" 'sleep 30' "$runtime sleep 30"
  expect_allow "$runtime" 'sleep 29' "$runtime sleep 29"
done
expect_block claude 'until grep -q done state; do sleep 1; done' 'until poll loop'
expect_block codex 'gh run watch 123' 'gh run watch'
expect_block grok 'gh pr checks --watch' 'gh pr checks --watch'
expect_block codex 'hq monitor list; sleep 300' 'monitor then sleep compound command'
expect_block grok 'hq monitor stop x && gh run watch 1' 'monitor then gh watch compound command'

echo '[2] exemptions and default-off behavior'
expect_allow claude 'sleep 30' 'Claude background command' true
expect_allow codex 'sleep 30' 'lane command' false lane-test
expect_allow grok "hq monitor start --description wait --command 'until ready; do sleep 30; done' --persistent" 'hq monitor command with quoted condition'
rc="$(run_guard claude 'sleep 30' false '' false)"
if [ "$rc" = 0 ] && ! jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null 2>&1; then ok 'default-off flag allows target'; else bad 'default-off flag allows target'; fi

: > "$TMP/flag-calls.log"
mkdir -p "$TMP_ROOT/workspace/logs"
: > "$TMP_ROOT/workspace/logs/hq-monitor-hook.log"
export HQ_TEST_NO_MONITOR=true
rc="$(run_guard codex 'sleep 30' false '' true old-cli-guard-session)"
unset HQ_TEST_NO_MONITOR
if [ "$rc" = 0 ] && ! jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null 2>&1 \
  && grep -Fq 'no monitor command' "$TMP_ROOT/workspace/logs/hq-monitor-hook.log"; then ok 'guard fails open when hq monitor enabled is unavailable'; else bad 'guard fails open when hq monitor enabled is unavailable'; fi

echo '[3] non-matching commands do not call hq monitor enabled'
for command_text in ls 'git status' 'npm test'; do
  : > "$TMP/flag-calls.log"
  rc="$(run_guard codex "$command_text")"
  if [ "$rc" = 0 ] && [ ! -s "$TMP/flag-calls.log" ]; then ok "$command_text skips hq monitor enabled"; else bad "$command_text skips hq monitor enabled"; fi
done

long_command="sleep 45 $(printf '%140s' '' | tr ' ' x)"
long_prefix="Blocked: ${long_command:0:117}..."
rc="$(run_guard codex "$long_command")"
if [ "$rc" = 0 ] && jq -e --arg prefix "$long_prefix" '.hookSpecificOutput.permissionDecisionReason | startswith($prefix) and endswith("Do not chain shorter sleeps to work around this block.")' "$TMP/stdout" >/dev/null; then ok 'deny reason truncates the command to 120 characters'; else bad 'deny reason truncates the command to 120 characters'; fi

echo '[4] session hooks stat-check before CLI calls'
: > "$TMP/flag-calls.log"
: > "$HQ_LOG"
empty_payload="$(jq -nc --arg sid monitor-session '{session_id:$sid,hook_event_name:"PreToolUse"}')"
printf '%s' "$empty_payload" | env "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=codex HQ_TEST_MONITOR_ENABLED=true HQ_TEST_MONITOR_ENABLED_CALL_MARKER="$TMP/flag-calls.log" bash "$SESSION" drain PreToolUse >"$TMP/stdout" 2>"$TMP/stderr"
if [ ! -s "$TMP/flag-calls.log" ] && [ ! -s "$HQ_LOG" ]; then ok 'empty active dir and inbox skip enabled query and CLI'; else bad 'empty active dir and inbox skip enabled query and CLI'; fi

session_dir="$TMP_ROOT/workspace/monitors/sessions/codex-monitor-session"
mkdir -p "$session_dir/active"
: > "$session_dir/active/watch-1"
: > "$TMP/flag-calls.log"
: > "$HQ_LOG"
drain_payload="$(jq -nc --arg sid monitor-session '{session_id:$sid,hook_event_name:"PreToolUse"}')"
printf '%s' "$drain_payload" | env "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=codex HQ_TEST_MONITOR_ENABLED=true HQ_TEST_MONITOR_ENABLED_CALL_MARKER="$TMP/flag-calls.log" bash "$SESSION" drain PreToolUse >"$TMP/stdout" 2>"$TMP/stderr"
if jq -e '.drained == true' "$TMP/stdout" >/dev/null && grep -Fq 'monitor drain --provider codex --event PreToolUse' "$HQ_LOG" && [ ! -s "$TMP/flag-calls.log" ]; then ok 'active Codex session drains through hq monitor without a hook flag lookup'; else bad 'active Codex session drains through hq monitor without a hook flag lookup'; fi

inbox_only_dir="$TMP_ROOT/workspace/monitors/sessions/grok-monitor-session"
mkdir -p "$inbox_only_dir/dropbox"
printf '%s\n' '{"event":"check-in"}' > "$inbox_only_dir/dropbox/inbox.jsonl"
: > "$HQ_LOG"
inbox_payload="$(jq -nc --arg sid monitor-session '{session_id:$sid,hook_event_name:"UserPromptSubmit"}')"
# Grok discards UserPromptSubmit output, so a drain there would lose the events.
printf '%s' "$inbox_payload" | env "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=grok HQ_TEST_MONITOR_ENABLED=true HQ_TEST_MONITOR_ENABLED_CALL_MARKER="$TMP/flag-calls.log" bash "$SESSION" drain UserPromptSubmit >"$TMP/stdout" 2>"$TMP/stderr"
if [ ! -s "$TMP/stdout" ] && [ ! -s "$HQ_LOG" ] && [ -s "$inbox_only_dir/dropbox/inbox.jsonl" ]; then ok 'Grok UserPromptSubmit leaves the inbox for the next tool call'; else bad "Grok UserPromptSubmit leaves the inbox for the next tool call (stdout=$(cat "$TMP/stdout") calls=$(cat "$HQ_LOG"))"; fi
pretool_inbox_payload="$(jq -nc --arg sid monitor-session '{session_id:$sid,hook_event_name:"PreToolUse"}')"
printf '%s' "$pretool_inbox_payload" | env "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=grok HQ_TEST_MONITOR_ENABLED=true HQ_TEST_MONITOR_ENABLED_CALL_MARKER="$TMP/flag-calls.log" bash "$SESSION" drain PreToolUse >"$TMP/stdout" 2>"$TMP/stderr"
if jq -e '.drained == true' "$TMP/stdout" >/dev/null && grep -Fq 'monitor drain --provider grok --event PreToolUse' "$HQ_LOG"; then ok 'nonempty Grok inbox drains on PreToolUse without active marker'; else bad 'nonempty Grok inbox drains on PreToolUse without active marker'; fi
: > "$HQ_LOG"
codex_inbox_dir="$TMP_ROOT/workspace/monitors/sessions/codex-inbox-session"
mkdir -p "$codex_inbox_dir/dropbox"
printf '%s\n' '{"event":"check-in"}' > "$codex_inbox_dir/dropbox/inbox.jsonl"
codex_prompt_payload="$(jq -nc --arg sid inbox-session '{session_id:$sid,hook_event_name:"UserPromptSubmit"}')"
printf '%s' "$codex_prompt_payload" | env "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=codex HQ_TEST_MONITOR_ENABLED=true HQ_TEST_MONITOR_ENABLED_CALL_MARKER="$TMP/flag-calls.log" bash "$SESSION" drain UserPromptSubmit >"$TMP/stdout" 2>"$TMP/stderr"
if jq -e '.drained == true' "$TMP/stdout" >/dev/null && grep -Fq 'monitor drain --provider codex --event UserPromptSubmit' "$HQ_LOG"; then ok 'Codex UserPromptSubmit still drains'; else bad 'Codex UserPromptSubmit still drains'; fi

echo '[5] Claude Stop waiter preserves the async wake contract'
stop_row="$(jq -c '[.hooks.Stop[]?.hooks[]? | select((.command | contains("hq-monitor-session-hook.sh")) and (.command | contains(" wait")))][0]' "$SETTINGS")"
if jq -e '.type == "command" and .asyncRewake == true and .timeout == 86400' <<<"$stop_row" >/dev/null; then ok 'Stop waiter is asyncRewake with 24-hour timeout'; else bad 'Stop waiter is asyncRewake with 24-hour timeout'; fi
claude_dir="$TMP_ROOT/workspace/monitors/sessions/claude-monitor-session"
mkdir -p "$claude_dir/active"
: > "$claude_dir/active/watch-1"
stop_payload="$(jq -nc --arg sid monitor-session '{session_id:$sid,hook_event_name:"Stop"}')"
rc=0
printf '%s' "$stop_payload" | env "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=claude HQ_TEST_MONITOR_ENABLED=true HQ_TEST_MONITOR_ENABLED_CALL_MARKER="$TMP/flag-calls.log" bash "$SESSION" wait >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 2 ] && jq -e '.wake == true' "$TMP/stdout" >/dev/null && grep -Fq 'monitor wait --provider claude' "$HQ_LOG"; then ok 'Claude Stop waiter propagates exit 2 wake'; else bad "Claude Stop waiter propagates exit 2 wake (rc=$rc stdout=$(cat "$TMP/stdout"))"; fi

echo '[6] Claude Stop waiter reads hook payload from a socket-backed stdin'
socket_session_dir="$TMP_ROOT/workspace/monitors/sessions/claude-socket-session"
mkdir -p "$socket_session_dir/active"
: > "$socket_session_dir/active/watch-1"
: > "$HQ_LOG"
socket_result=0
env "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=claude HQ_TEST_MONITOR_ENABLED=true \
  node - "$SESSION" "$TMP_ROOT" "$TMP" <<'NODE' || socket_result=$?
const fs = require('fs');
const net = require('net');
const { spawn } = require('child_process');
const path = require('path');

const [sessionHook, root, tmp] = process.argv.slice(2);
const socketPath = path.join(tmp, 'monitor-stop.sock');
const payload = JSON.stringify({ hook_event_name: 'Stop', session_id: 'socket-session' });
let childProcess;
const failTimer = setTimeout(() => {
  fs.writeFileSync(path.join(tmp, 'socket-error'), 'timed out waiting for socket-backed hook');
  if (childProcess) childProcess.kill('SIGKILL');
  server.close();
  process.exitCode = 1;
}, 5000);
const server = net.createServer((accepted) => {
  childProcess = spawn('bash', [sessionHook, 'wait'], {
    env: { ...process.env, HQ_ROOT: root, CLAUDE_PROJECT_DIR: root, HQ_CHECKPOINT_RUNTIME: 'claude' },
    stdio: [accepted._handle.fd, 'pipe', 'pipe'],
  });
  accepted.destroy();
  let stdout = '';
  let stderr = '';
  childProcess.stdout.setEncoding('utf8').on('data', (chunk) => { stdout += chunk; });
  childProcess.stderr.setEncoding('utf8').on('data', (chunk) => { stderr += chunk; });
  childProcess.on('error', (error) => { fs.writeFileSync(path.join(tmp, 'socket-error'), error.message); });
  childProcess.on('close', (code) => {
    clearTimeout(failTimer);
    fs.writeFileSync(path.join(tmp, 'socket-stdout'), stdout);
    fs.writeFileSync(path.join(tmp, 'socket-stderr'), stderr);
    fs.writeFileSync(path.join(tmp, 'socket-exit'), String(code));
    server.close();
  });
});
server.on('error', (error) => { clearTimeout(failTimer); fs.writeFileSync(path.join(tmp, 'socket-error'), error.message); process.exitCode = 1; });
server.listen(socketPath, () => {
  const sender = net.createConnection(socketPath, () => sender.end(payload));
  sender.on('error', (error) => { fs.writeFileSync(path.join(tmp, 'socket-error'), error.message); process.exitCode = 1; });
});
NODE
socket_rc="$(cat "$TMP/socket-exit" 2>/dev/null || true)"
if [ "$socket_result" = 0 ] && [ "$socket_rc" = 2 ] \
    && jq -e '.wake == true' "$TMP/socket-stdout" >/dev/null \
    && grep -Fq 'monitor wait --provider claude' "$HQ_LOG" \
    && grep -Fq 'socket-session' "$HQ_INPUT" \
    && [ ! -s "$TMP/socket-stderr" ]; then
  ok 'Claude Stop waiter drains the session payload from socket stdin'
else
  bad "Claude Stop waiter drains the session payload from socket stdin (node_rc=$socket_result rc=$socket_rc stdout=$(cat "$TMP/socket-stdout" 2>/dev/null) stderr=$(cat "$TMP/socket-stderr" 2>/dev/null) error=$(cat "$TMP/socket-error" 2>/dev/null))"
fi

echo '[7] hook registry keeps the candidate filter and provider registrations'
guard_row="$(jq -c '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.id == "hq-monitor-guard")][0]' "$REGISTRY")"
if jq -e '.script == ".claude/hooks/hq-monitor-guard.sh" and .gated == true and .prefilter.re == "sleep|watch|until|while"' <<<"$guard_row" >/dev/null; then ok 'guard is gated and filtered to candidate commands'; else bad 'guard is gated and filtered to candidate commands'; fi
pretool_drain="$(jq -c '[.hooks.PreToolUse[] | select(.matcher == "") | .hooks[] | select(.id == "hq-monitor-session-hook" and .args == ["drain", "PreToolUse"]) ]' "$REGISTRY")"
prompt_drain="$(jq -c '[.hooks.UserPromptSubmit[] | select(.matcher == "") | .hooks[] | select(.id == "hq-monitor-session-hook" and .args == ["drain", "UserPromptSubmit"]) ]' "$REGISTRY")"
session_start="$(jq -c '[.hooks.SessionStart[] | select(.matcher == "") | .hooks[] | select(.id == "hq-monitor-session-start")]' "$REGISTRY")"
if jq -e 'length == 1 and .[0].gated == true' <<<"$pretool_drain" >/dev/null && jq -e 'length == 1 and .[0].gated == true' <<<"$prompt_drain" >/dev/null && jq -e 'length == 1 and .[0].gated == true' <<<"$session_start" >/dev/null; then ok 'drain and SessionStart guidance use the registry'; else bad 'drain and SessionStart guidance use the registry'; fi

echo '[8] Codex and Grok resolve monitor hooks through adapter registry dispatch'
. "$ROOT/.claude/hooks/hook-gate.sh" --lib
for runtime in codex grok; do
  export HQ_ROOT="$TMP_ROOT" HQ_CHECKPOINT_RUNTIME="$runtime"
  . "$ADAPTER_CORE"
  candidate_payload="$(payload "$runtime" 'sleep 45')"
  records="$(hqad_iter_settings PreToolUse Bash "$candidate_payload")"
  if printf '%s' "$records" | grep -Fq 'hq-monitor-guard.sh'; then ok "$runtime adapter dispatches the guard from the registry"; else bad "$runtime adapter dispatches the guard from the registry"; fi
  if printf '%s' "$records" | grep -Fq 'hq-monitor-session-hook.sh' && printf '%s' "$records" | grep -Fq $'master\tPreToolUse'; then ok "$runtime adapter keeps drain and master dispatch"; else bad "$runtime adapter keeps drain and master dispatch"; fi
  records="$(hqad_iter_settings UserPromptSubmit ANY '{}')"
  if printf '%s' "$records" | grep -Fq 'hq-monitor-session-hook.sh'; then ok "$runtime adapter dispatches prompt drain from the registry"; else bad "$runtime adapter dispatches prompt drain from the registry"; fi
  records="$(hqad_iter_settings SessionStart ANY '{}')"
  if printf '%s' "$records" | grep -Fq 'hq-monitor-session-start.sh'; then ok "$runtime adapter dispatches SessionStart guidance from the registry"; else bad "$runtime adapter dispatches SessionStart guidance from the registry"; fi
  records="$(hqad_iter_settings Stop ANY '{}')"
  if ! printf '%s' "$records" | grep -Fq 'hq-monitor-session-hook.sh'; then ok "$runtime adapter skips Stop waiter"; else bad "$runtime adapter skips Stop waiter"; fi
done
export HQ_ROOT="$ROOT" HQ_CHECKPOINT_RUNTIME=claude
. "$ADAPTER_CORE"
records="$(hqad_iter_settings Stop ANY '{}')"
if printf '%s' "$records" | grep -Fq 'hq-monitor-session-hook.sh'; then ok 'Claude-compatible settings retain Stop waiter'; else bad 'Claude-compatible settings retain Stop waiter'; fi

echo '[9] the real provider adapters carry registry denies and drains'
codex_block_payload="$(jq -nc --arg root "$TMP_ROOT" --arg sid codex-adapter-session '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,session_id:$sid,tool_input:{command:"sleep 45"}}')"
rc=0
printf '%s' "$codex_block_payload" | env -u HQ_LANE_ID "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=codex HQ_TEST_MONITOR_ENABLED=true bash "$TMP_ROOT/.codex/hooks/hq-codex-hook-adapter.sh" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 0 ] && jq -e '(.decision == "deny" or .decision == "block") and ((.reason // .message // "") | contains("Blocked: sleep 45"))' "$TMP/stdout" >/dev/null; then ok 'Codex adapter returns the registry guard denial and reason'; else bad "Codex adapter returns the registry guard denial and reason (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi

grok_block_payload="$(jq -nc --arg root "$TMP_ROOT" --arg sid grok-adapter-session '{hookEventName:"PreToolUse",toolName:"Shell",cwd:$root,session_id:$sid,toolInput:{command:"sleep 45"}}')"
rc=0
printf '%s' "$grok_block_payload" | env -u HQ_LANE_ID "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=grok HQ_TEST_MONITOR_ENABLED=true bash "$TMP_ROOT/.grok/hooks/hq-grok-hook-adapter.sh" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 2 ] && jq -e '.decision == "deny" and (.reason | contains("Blocked: sleep 45"))' "$TMP/stdout" >/dev/null; then ok 'Grok adapter returns the registry guard denial and reason'; else bad "Grok adapter returns the registry guard denial and reason (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi

for runtime in codex grok; do
  session_dir="$TMP_ROOT/workspace/monitors/sessions/$runtime-${runtime}-adapter-session"
  mkdir -p "$session_dir/active"
  : > "$session_dir/active/watch-1"
  : > "$HQ_LOG"
  if [ "$runtime" = codex ]; then
    adapter_payload="$(jq -nc --arg root "$TMP_ROOT" --arg sid codex-adapter-session '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,session_id:$sid,tool_input:{command:"ls"}}')"
    adapter="$TMP_ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
  else
    adapter_payload="$(jq -nc --arg root "$TMP_ROOT" --arg sid grok-adapter-session '{hookEventName:"PreToolUse",toolName:"Shell",cwd:$root,session_id:$sid,toolInput:{command:"ls"}}')"
    adapter="$TMP_ROOT/.grok/hooks/hq-grok-hook-adapter.sh"
  fi
  printf '%s' "$adapter_payload" | env -u HQ_LANE_ID "${base_env[@]}" HQ_CHECKPOINT_RUNTIME="$runtime" HQ_TEST_MONITOR_ENABLED=true bash "$adapter" >"$TMP/stdout" 2>"$TMP/stderr"
  if grep -Fq "monitor drain --provider $runtime --event PreToolUse" "$HQ_LOG"; then ok "$runtime adapter drains the active session through the registry"; else bad "$runtime adapter drains the active session through the registry"; fi
done

echo '[9b] the Grok adapter hands drained monitor events to the model'
# Grok reads hookSpecificOutput.additionalContext from a settings-file command
# hook on PreToolUse and PostToolUse and shows it next to the tool result.
grok_ctx_payload() { # <event> <command>
  jq -nc --arg root "$TMP_ROOT" --arg event "$1" --arg command "$2" --arg sid grok-adapter-session \
    '{hookEventName:$event,toolName:"Shell",cwd:$root,session_id:$sid,toolInput:{command:$command}}'
}
rc=0
grok_ctx_payload PreToolUse ls | env -u HQ_LANE_ID "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=grok HQ_TEST_MONITOR_ENABLED=true HQ_TEST_DRAIN_CONTEXT='MON-EVT-4411 build finished' bash "$TMP_ROOT/.grok/hooks/hq-grok-hook-adapter.sh" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 0 ] && jq -e '.decision == "allow" and .hookSpecificOutput.hookEventName == "PreToolUse" and (.hookSpecificOutput.additionalContext | contains("MON-EVT-4411 build finished"))' "$TMP/stdout" >/dev/null && ! grep -Fq 'MON-EVT-4411' "$TMP/stderr"; then ok 'Grok PreToolUse returns drained events as additionalContext'; else bad "Grok PreToolUse returns drained events as additionalContext (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi
rc=0
grok_ctx_payload PreToolUse ls | env -u HQ_LANE_ID "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=grok HQ_TEST_MONITOR_ENABLED=true bash "$TMP_ROOT/.grok/hooks/hq-grok-hook-adapter.sh" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$TMP/stdout")" = '{"decision":"allow"}' ]; then ok 'Grok PreToolUse without context stays a plain allow'; else bad "Grok PreToolUse without context stays a plain allow (rc=$rc stdout=$(cat "$TMP/stdout"))"; fi
# The drain runs before the Bash guard. Grok drops additionalContext on a deny,
# so the drained events must ride in the deny reason.
rc=0
grok_ctx_payload PreToolUse 'sleep 45' | env -u HQ_LANE_ID "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=grok HQ_TEST_MONITOR_ENABLED=true HQ_TEST_DRAIN_CONTEXT='MON-EVT-4412 deploy done' bash "$TMP_ROOT/.grok/hooks/hq-grok-hook-adapter.sh" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 2 ] && jq -e '.decision == "deny" and (.reason | contains("Blocked: sleep 45")) and (.reason | contains("MON-EVT-4412 deploy done"))' "$TMP/stdout" >/dev/null; then ok 'Grok deny carries drained events in the reason'; else bad "Grok deny carries drained events in the reason (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi
# PostToolUse: a registry advisory hook's additionalContext reaches the model.
cat > "$TMP_ROOT/.claude/hooks/test-post-context.sh" <<'SH'
#!/bin/bash
cat >/dev/null
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"POST-NOTE-5521"}}'
SH
cp "$TMP_ROOT/.claude/hooks/hook-registry.json" "$TMP/registry.json.orig"
# Gated hooks are the ones whose stdout the adapter reads, and the profile gate
# only runs known ids, so the test script borrows a monitor hook id.
add_test_hook() { # <event>: the test hook is the only registry hook for <event>
  jq --arg ev "$1" '.hooks[$ev] = [{matcher:"",hooks:[{id:"hq-monitor-session-start",script:".claude/hooks/test-post-context.sh",timeout:10,gated:true}]}]' "$TMP/registry.json.orig" > "$TMP_ROOT/.claude/hooks/hook-registry.json"
}
add_test_hook PostToolUse
rc=0
grok_ctx_payload PostToolUse ls | env -u HQ_LANE_ID "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=grok HQ_TEST_MONITOR_ENABLED=true bash "$TMP_ROOT/.grok/hooks/hq-grok-hook-adapter.sh" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and .hookSpecificOutput.additionalContext == "POST-NOTE-5521"' "$TMP/stdout" >/dev/null; then ok 'Grok PostToolUse returns hook additionalContext'; else bad "Grok PostToolUse returns hook additionalContext (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi
# SessionStart cannot carry context under Grok: stdout stays empty and the
# hook's note stays visible as stderr diagnostics instead of being swallowed.
add_test_hook SessionStart
rc=0
grok_ctx_payload SessionStart '' | env -u HQ_LANE_ID "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=grok HQ_TEST_MONITOR_ENABLED=false bash "$TMP_ROOT/.grok/hooks/hq-grok-hook-adapter.sh" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/stdout" ] && grep -Fq 'POST-NOTE-5521' "$TMP/stderr"; then ok 'Grok SessionStart keeps hook context as diagnostics'; else bad "Grok SessionStart keeps hook context as diagnostics (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi
cp "$TMP/registry.json.orig" "$TMP_ROOT/.claude/hooks/hook-registry.json"
rm -f "$TMP_ROOT/.claude/hooks/test-post-context.sh"

echo '[9c] the Grok adapter gates Stop and SubagentStop'
# Grok 1.0.34 Stop Decision Control: {"decision":"block","reason":...} on stdout
# keeps the agent working, exit 2 blocks with stderr as the feedback, and any
# other non-zero exit fails open. The adapter dispatched Stop advisory and
# dropped all three until 2026-09-26.
grok_stop_payload() { # <event> <stopHookActive> [reason] [session-id]
  jq -nc --arg event "$1" --argjson active "$2" --arg reason "${3:-end_turn}" \
    --arg root "$TMP_ROOT" --arg sid "${4:-grok-stop-session}" \
    '{hookEventName:$event,cwd:$root,session_id:$sid,stopHookActive:$active,reason:$reason}'
}
run_grok_stop() { # <event> <stopHookActive> [reason] [session-id] -> rc, writes $TMP/stdout,$TMP/stderr
  local rc=0
  grok_stop_payload "$1" "$2" "${3:-end_turn}" "${4:-grok-stop-session}" \
    | env -u HQ_LANE_ID "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=grok HQ_TEST_MONITOR_ENABLED=false \
        bash "$TMP_ROOT/.grok/hooks/hq-grok-hook-adapter.sh" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  printf '%s' "$rc"
}

# A Stop gate that blocks, and echoes back the stop_hook_active it was handed.
# Every HQ Stop gate that can block reads that field to block at most once per
# chain, so the adapter failing to forward Grok's stopHookActive would turn each
# of them into an unguarded blocker.
cat > "$TMP_ROOT/.claude/hooks/test-stop-block.sh" <<'SH'
#!/bin/bash
payload="$(cat 2>/dev/null || printf '{}')"
active="$(printf '%s' "$payload" | jq -r 'if has("stop_hook_active") then (.stop_hook_active | tostring) else "absent" end' 2>/dev/null || printf 'absent')"
printf '{"decision":"block","reason":"STOP-GATE-7781 checkpoint required (stop_hook_active=%s)"}\n' "$active"
SH
# Pretty-printed, spaced JSON: the bash prefilter in collect_stop_block keys on
# the literal `"decision"`, which must not be defeated by a hook that formats
# its output differently from the compact form jq emits.
cat > "$TMP_ROOT/.claude/hooks/test-stop-block-spaced.sh" <<'SH'
#!/bin/bash
cat >/dev/null
printf '%s\n' '{'
printf '%s\n' '  "decision" : "block" ,'
printf '%s\n' '  "reason"   : "STOP-SPACED-7785 formatted differently"'
printf '%s\n' '}'
SH
cat > "$TMP_ROOT/.claude/hooks/test-stop-block-second.sh" <<'SH'
#!/bin/bash
cat >/dev/null
printf '%s\n' '{"decision":"block","reason":"STOP-SECOND-7786 conductor message"}'
SH
cat > "$TMP_ROOT/.claude/hooks/test-stop-exit2.sh" <<'SH'
#!/bin/bash
cat >/dev/null
printf 'STOP-STDERR-7782 run the linter before finishing\n' >&2
exit 2
SH
cat > "$TMP_ROOT/.claude/hooks/test-stop-crash.sh" <<'SH'
#!/bin/bash
cat >/dev/null
printf 'STOP-CRASH-7783 the gate itself broke\n' >&2
exit 3
SH
cat > "$TMP_ROOT/.claude/hooks/test-stop-context.sh" <<'SH'
#!/bin/bash
cat >/dev/null
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"STOP-NOTE-7784"}}'
SH
chmod +x "$TMP_ROOT/.claude/hooks/test-stop-block.sh" "$TMP_ROOT/.claude/hooks/test-stop-exit2.sh" \
  "$TMP_ROOT/.claude/hooks/test-stop-crash.sh" "$TMP_ROOT/.claude/hooks/test-stop-context.sh" \
  "$TMP_ROOT/.claude/hooks/test-stop-block-spaced.sh" "$TMP_ROOT/.claude/hooks/test-stop-block-second.sh"

set_stop_hook() { # <event> <script-basename>: the only registry hook for <event>
  jq --arg ev "$1" --arg script ".claude/hooks/$2" \
    '.hooks[$ev] = [{matcher:"",hooks:[{id:"hq-monitor-session-start",script:$script,timeout:30,gated:true}]}]' \
    "$TMP/registry.json.orig" > "$TMP_ROOT/.claude/hooks/hook-registry.json"
}

set_stop_hook Stop test-stop-block.sh
rc="$(run_grok_stop Stop false)"
if [ "$rc" = 0 ] && jq -e '.decision == "block" and (.reason | contains("STOP-GATE-7781"))' "$TMP/stdout" >/dev/null; then ok 'Grok Stop turns a hook block decision into a Stop block'; else bad "Grok Stop turns a hook block decision into a Stop block (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi
if jq -e '.reason | contains("stop_hook_active=false")' "$TMP/stdout" >/dev/null; then ok 'Grok stopHookActive reaches the hook as stop_hook_active'; else bad "Grok stopHookActive reaches the hook as stop_hook_active (stdout=$(cat "$TMP/stdout"))"; fi
rc="$(run_grok_stop Stop true '' grok-stop-forward)"
if jq -e '.reason | contains("stop_hook_active=true")' "$TMP/stdout" >/dev/null; then ok 'a true stopHookActive is forwarded, not defaulted to false'; else bad "a true stopHookActive is forwarded, not defaulted to false (stdout=$(cat "$TMP/stdout"))"; fi

# Grok fires an extra observe-only Stop at session close whose decision it
# discards; blocking a turn that no longer exists is noise.
rc="$(run_grok_stop Stop false channel_closed)"
if [ "$rc" = 0 ] && [ ! -s "$TMP/stdout" ]; then ok 'the session-close Stop emits no block'; else bad "the session-close Stop emits no block (rc=$rc stdout=$(cat "$TMP/stdout"))"; fi

set_stop_hook SubagentStop test-stop-block.sh
rc="$(run_grok_stop SubagentStop false)"
if [ "$rc" = 0 ] && jq -e '.decision == "block" and (.reason | contains("STOP-GATE-7781"))' "$TMP/stdout" >/dev/null; then ok 'Grok SubagentStop gates like Stop'; else bad "Grok SubagentStop gates like Stop (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi

# Codex review P1: a later gate's block used to be discarded by a first-wins
# guard. Every Stop gate has already had its side effects by then —
# conduct-lane-inbox has DRAINED its queue — so dropping the reason destroys the
# message it just consumed.
jq --arg a ".claude/hooks/test-stop-block.sh" --arg b ".claude/hooks/test-stop-block-second.sh" \
  '.hooks.Stop = [{matcher:"",hooks:[
     {id:"hq-monitor-session-start",script:$a,timeout:30,gated:true},
     {id:"hq-monitor-session-hook",script:$b,timeout:30,gated:true}]}]' \
  "$TMP/registry.json.orig" > "$TMP_ROOT/.claude/hooks/hook-registry.json"
rc="$(run_grok_stop Stop false)"
if [ "$rc" = 0 ] && jq -e '(.reason | contains("STOP-GATE-7781")) and (.reason | contains("STOP-SECOND-7786"))' "$TMP/stdout" >/dev/null; then ok 'a later Stop gate block is merged, not discarded'; else bad "a later Stop gate block is merged, not discarded (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi

set_stop_hook Stop test-stop-block-spaced.sh
rc="$(run_grok_stop Stop false)"
if [ "$rc" = 0 ] && jq -e '.decision == "block" and (.reason | contains("STOP-SPACED-7785"))' "$TMP/stdout" >/dev/null; then ok 'a block survives multi-line, spaced JSON from a hook'; else bad "a block survives multi-line, spaced JSON from a hook (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi

set_stop_hook Stop test-stop-exit2.sh
rc="$(run_grok_stop Stop false)"
if [ "$rc" = 0 ] && jq -e '.decision == "block" and (.reason | contains("STOP-STDERR-7782"))' "$TMP/stdout" >/dev/null; then ok 'Grok Stop turns exit 2 + stderr into a block'; else bad "Grok Stop turns exit 2 + stderr into a block (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi

set_stop_hook Stop test-stop-crash.sh
rc="$(run_grok_stop Stop false)"
if [ "$rc" = 0 ] && [ ! -s "$TMP/stdout" ] && grep -Fq 'STOP-CRASH-7783' "$TMP/stderr"; then ok 'a Stop hook crashing with a non-2 exit fails open'; else bad "a Stop hook crashing with a non-2 exit fails open (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi

# additionalContext on Stop is not passive context in Grok: it also keeps the
# agent working. Relaying a hook's incidental note would silently convert a
# diagnostic into a continuation, so it stays in the stderr stream.
set_stop_hook Stop test-stop-context.sh
rc="$(run_grok_stop Stop false)"
if [ "$rc" = 0 ] && [ ! -s "$TMP/stdout" ] && grep -Fq 'STOP-NOTE-7784' "$TMP/stderr"; then ok 'Stop-hook additionalContext stays a diagnostic and never forces a continuation'; else bad "Stop-hook additionalContext stays a diagnostic and never forces a continuation (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi

# Codex review P1: on the session-close Stop the adapter must tell hooks that
# nothing they write can reach the model, BEFORE they run. A hook that drains a
# queue on that fire destroys the message instead of delaying it.
cat > "$TMP_ROOT/.claude/hooks/test-stop-deliverable.sh" <<'SH'
#!/bin/bash
cat >/dev/null
printf 'DELIVERABLE=%s\n' "${HQ_STOP_DECISION_DELIVERABLE:-unset}"
SH
chmod +x "$TMP_ROOT/.claude/hooks/test-stop-deliverable.sh"
set_stop_hook Stop test-stop-deliverable.sh
rc="$(run_grok_stop Stop false end_turn)"
if grep -Fq 'DELIVERABLE=1' "$TMP/stderr"; then ok 'a real turn end tells hooks their decision is deliverable'; else bad "a real turn end tells hooks their decision is deliverable (stderr=$(cat "$TMP/stderr"))"; fi
rc="$(run_grok_stop Stop false shutdown)"
if grep -Fq 'DELIVERABLE=0' "$TMP/stderr"; then ok 'the session-close Stop warns hooks before they run'; else bad "the session-close Stop warns hooks before they run (stderr=$(cat "$TMP/stderr"))"; fi

# Codex review P1: transcript_path and last_assistant_message must reach the
# Claude-shaped payload; the Stop gates that read a transcript get nothing
# without them.
cat > "$TMP_ROOT/.claude/hooks/test-stop-payload.sh" <<'SH'
#!/bin/bash
payload="$(cat 2>/dev/null || printf '{}')"
printf 'PAYLOAD=%s\n' "$(printf '%s' "$payload" | jq -c '{t:(.transcript_path // "ABSENT"),l:(.last_assistant_message // "ABSENT")}')"
SH
chmod +x "$TMP_ROOT/.claude/hooks/test-stop-payload.sh"
set_stop_hook Stop test-stop-payload.sh
rc=0
jq -nc --arg root "$TMP_ROOT" --arg sid grok-stop-payload \
  '{hookEventName:"Stop",cwd:$root,session_id:$sid,stopHookActive:false,reason:"end_turn",transcriptPath:"/tmp/grok-transcript.jsonl",lastAssistantMessage:"THE-LAST-WORD"}' \
  | env -u HQ_LANE_ID "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=grok HQ_TEST_MONITOR_ENABLED=false \
      bash "$TMP_ROOT/.grok/hooks/hq-grok-hook-adapter.sh" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if grep -Fq '"t":"/tmp/grok-transcript.jsonl"' "$TMP/stderr" && grep -Fq '"l":"THE-LAST-WORD"' "$TMP/stderr"; then ok 'Grok transcriptPath and lastAssistantMessage reach the Claude-shaped payload'; else bad "Grok transcriptPath and lastAssistantMessage reach the Claude-shaped payload (stderr=$(cat "$TMP/stderr"))"; fi

# Loop guard: a gate whose condition never clears must not spin the turn all the
# way to Grok's own 8-continuation ceiling.
set_stop_hook Stop test-stop-block.sh
rm -f "$TMP_ROOT/workspace/orchestrator/hook-state/grok-stop-blocks-"*
blocks=0
rc="$(run_grok_stop Stop false '' grok-stop-loop)"
jq -e '.decision == "block"' "$TMP/stdout" >/dev/null 2>&1 && blocks=$((blocks + 1))
for _ in 1 2 3 4 5; do
  rc="$(run_grok_stop Stop true '' grok-stop-loop)"
  jq -e '.decision == "block"' "$TMP/stdout" >/dev/null 2>&1 && blocks=$((blocks + 1))
done
if [ "$blocks" = 3 ]; then ok 'the adapter stops blocking after HQ_GROK_STOP_BLOCK_MAX consecutive blocks'; else bad "the adapter stops blocking after HQ_GROK_STOP_BLOCK_MAX consecutive blocks (emitted $blocks)"; fi
if [ ! -s "$TMP/stdout" ] && grep -Fq 'asked to hold the turn again' "$TMP/stderr"; then ok 'the suppressed block is reported instead of swallowed'; else bad "the suppressed block is reported instead of swallowed (stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi
# A fresh chain (stopHookActive false) resets the count.
rc="$(run_grok_stop Stop false '' grok-stop-loop)"
if jq -e '.decision == "block"' "$TMP/stdout" >/dev/null 2>&1; then ok 'a new stop chain resets the block budget'; else bad "a new stop chain resets the block budget (stdout=$(cat "$TMP/stdout"))"; fi

# PostToolUse must dispatch for tools the adapter has no special payload shape
# for, or a matcher-`*` hook (conduct-lane-inbox) never fires for a lane that
# spends a stretch doing nothing but greps.
cat > "$TMP_ROOT/.claude/hooks/test-post-context.sh" <<'SH'
#!/bin/bash
cat >/dev/null
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"POST-NOTE-5521"}}'
SH
add_test_hook PostToolUse
rc=0
jq -nc --arg root "$TMP_ROOT" --arg sid grok-adapter-session \
  '{hookEventName:"PostToolUse",toolName:"grep",cwd:$root,session_id:$sid,toolInput:{pattern:"x",path:"core/"}}' \
  | env -u HQ_LANE_ID "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=grok HQ_TEST_MONITOR_ENABLED=false \
      bash "$TMP_ROOT/.grok/hooks/hq-grok-hook-adapter.sh" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.additionalContext == "POST-NOTE-5521"' "$TMP/stdout" >/dev/null; then ok 'Grok PostToolUse dispatches for an unmapped tool'; else bad "Grok PostToolUse dispatches for an unmapped tool (rc=$rc stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"; fi

cp "$TMP/registry.json.orig" "$TMP_ROOT/.claude/hooks/hook-registry.json"
rm -f "$TMP_ROOT/.claude/hooks/test-stop-block.sh" "$TMP_ROOT/.claude/hooks/test-stop-exit2.sh" \
  "$TMP_ROOT/.claude/hooks/test-stop-crash.sh" "$TMP_ROOT/.claude/hooks/test-stop-context.sh" \
  "$TMP_ROOT/.claude/hooks/test-stop-block-spaced.sh" "$TMP_ROOT/.claude/hooks/test-post-context.sh" \
  "$TMP_ROOT/.claude/hooks/test-stop-block-second.sh" "$TMP_ROOT/.claude/hooks/test-stop-deliverable.sh" \
  "$TMP_ROOT/.claude/hooks/test-stop-payload.sh"

echo '[10] monitor hooks are enabled in the same profiles as the wait guard'
for profile in minimal standard strict; do
  for id in hq-monitor-guard hq-monitor-session-hook hq-monitor-session-start; do
    if hq_hook_profile_allows "$id" "$profile"; then ok "$profile profile includes $id"; else bad "$profile profile includes $id"; fi
  done
done

echo '[11] SessionStart text is limited to enabled Codex and Grok sessions'
for runtime in codex grok; do
  : > "$TMP/flag-calls.log"
  printf '{}' | env "${base_env[@]}" HQ_CHECKPOINT_RUNTIME="$runtime" HQ_TEST_MONITOR_ENABLED=true HQ_TEST_MONITOR_ENABLED_CALL_MARKER="$TMP/flag-calls.log" bash "$START" >"$TMP/stdout" 2>"$TMP/stderr"
  if grep -Fq 'hq monitor start' "$TMP/stdout" && grep -Fq 'every 55 minutes' "$TMP/stdout" && [ -s "$TMP/flag-calls.log" ]; then ok "$runtime SessionStart guidance follows monitor.enabled"; else bad "$runtime SessionStart guidance follows monitor.enabled"; fi
done
printf '{}' | env "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=claude HQ_TEST_MONITOR_ENABLED=true bash "$START" >"$TMP/stdout" 2>"$TMP/stderr"
if [ ! -s "$TMP/stdout" ]; then ok 'Claude SessionStart does not print adapter guidance'; else bad 'Claude SessionStart does not print adapter guidance'; fi

echo '[12] an older hq CLI exits quietly and logs once'
: > "$HQ_LOG"
: > "$TMP/flag-calls.log"
export HQ_TEST_NO_MONITOR=true
rc=0
: > "$TMP_ROOT/workspace/logs/hq-monitor-hook.log"
printf '%s' "$drain_payload" | env "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=codex HQ_TEST_MONITOR_ENABLED=true HQ_TEST_MONITOR_ENABLED_CALL_MARKER="$TMP/flag-calls.log" bash "$SESSION" drain PreToolUse >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
printf '%s' "$drain_payload" | env "${base_env[@]}" HQ_CHECKPOINT_RUNTIME=codex HQ_TEST_MONITOR_ENABLED=true HQ_TEST_MONITOR_ENABLED_CALL_MARKER="$TMP/flag-calls.log" bash "$SESSION" drain PreToolUse >"$TMP/stdout2" 2>"$TMP/stderr2" || rc=$?
old_cli_warnings="$(grep -c 'no monitor command' "$TMP_ROOT/workspace/logs/hq-monitor-hook.log" 2>/dev/null || true)"
if [ "$rc" = 0 ] && [ ! -s "$TMP/stdout2" ] && [ ! -s "$TMP/stderr2" ] && [ "$old_cli_warnings" = 1 ]; then ok 'old hq CLI fails open silently and logs once'; else bad "old hq CLI fails open silently and logs once (rc=$rc warnings=$old_cli_warnings stdout=$(cat "$TMP/stdout2") stderr=$(cat "$TMP/stderr2") log=$(cat "$TMP_ROOT/workspace/logs/hq-monitor-hook.log" 2>/dev/null))"; fi
unset HQ_TEST_NO_MONITOR

echo '[13] a missing hq binary exits quietly and logs once'
: > "$HQ_LOG"
rc=0
printf '%s' "$drain_payload" | env PATH=/usr/bin:/bin HQ_ROOT="$TMP_ROOT" CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_CHECKPOINT_RUNTIME=codex bash "$SESSION" drain PreToolUse >"$TMP/no-hq.out" 2>"$TMP/no-hq.err" || rc=$?
printf '%s' "$drain_payload" | env PATH=/usr/bin:/bin HQ_ROOT="$TMP_ROOT" CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_CHECKPOINT_RUNTIME=codex bash "$SESSION" drain PreToolUse >"$TMP/no-hq2.out" 2>"$TMP/no-hq2.err" || rc=$?
missing_cli_warnings="$(grep -c 'hq is unavailable' "$TMP_ROOT/workspace/logs/hq-monitor-hook.log" 2>/dev/null || true)"
if [ "$rc" = 0 ] && [ ! -s "$TMP/no-hq.out" ] && [ ! -s "$TMP/no-hq.err" ] && [ ! -s "$TMP/no-hq2.err" ] && [ "$missing_cli_warnings" = 1 ]; then ok 'missing hq binary fails open silently and logs once'; else bad 'missing hq binary fails open silently and logs once'; fi

echo '[14] mutation guards: lane exemption and the inbox fast path'
if grep -Fq '[ "${HQ_LANE_ID+x}" = x ] && exit 0' "$GUARD"; then ok 'lane exemption is explicit and test-covered'; else bad 'lane exemption is explicit and test-covered'; fi
if grep -Fq '[ "$active" -eq 0 ] && [ ! -s "$inbox" ]; then' "$SESSION"; then ok 'stat fast path is explicit and test-covered'; else bad 'stat fast path is explicit and test-covered'; fi

echo "hq-monitor-hooks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
