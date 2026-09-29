#!/usr/bin/env bash
# Portable PATH-shim exec inventory for the PreToolUse monitor guard.
set -uo pipefail
unset HQ_LANE_ID

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
HOOK="${HQ_TEST_MONITOR_GUARD_HOOK:-$ROOT/.claude/hooks/hq-monitor-guard.sh}"
BASH_BIN="$(command -v bash)"
ORIGINAL_PATH="$PATH"
REAL_JQ="$(PATH="$ORIGINAL_PATH" command -v jq 2>/dev/null || true)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/root/.claude/hooks"
printf '#!/bin/bash\n' > "$TMP/root/.claude/hooks/hook-gate.sh"
: > "$TMP/process.log"
export PROCESS_LOG="$TMP/process.log"

for program in awk env dirname grep mkdir mv; do
  real="$(PATH="$ORIGINAL_PATH" command -v "$program" 2>/dev/null || true)"
  [ -n "$real" ] || continue
  printf -v real_q '%q' "$real"
  printf '#!/bin/bash\nprintf "%%s\\n" "%s" >> "$PROCESS_LOG"\nexec %s "$@"\n' \
    "$program" "$real_q" > "$BIN/$program"
  chmod 700 "$BIN/$program"
done
if [ -n "$REAL_JQ" ]; then
  cat > "$BIN/jq" <<'SH'
#!/bin/bash
printf '%s\n' jq >> "$PROCESS_LOG"
if [ "${HQ_TEST_JQ_CRLF:-0}" = 1 ]; then
  output="$("$HQ_TEST_REAL_JQ" "$@"; printf '\001')"
  output="${output%$'\001'}"
  output="${output//$'\r\n'/$'\n'}"
  output="${output//$'\n'/$'\r\n'}"
  printf '%s' "$output"
else
  exec "$HQ_TEST_REAL_JQ" "$@"
fi
SH
  chmod 700 "$BIN/jq"
fi
cat > "$BIN/hq" <<'SH'
#!/bin/bash
printf '%s\n' hq >> "$PROCESS_LOG"
if [ "${1:-}" = monitor ] && [ "${2:-}" = enabled ]; then
  exit "${HQ_TEST_MONITOR_ENABLED_RC:-0}"
fi
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Usage: hq [command]' '  monitor  Monitor session events'
  exit 0
fi
exit 0
SH
chmod 700 "$BIN/hq"
touch -t 200001010000 "$BIN/hq"

FAIL=0
pass() { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
total_launches() {
  local count=0 line
  while IFS= read -r line; do count=$((count + 1)); done < "$PROCESS_LOG"
  printf '%s' "$count"
}
print_inventory() {
  local program count line
  for program in jq awk env dirname grep mkdir mv hq; do
    count=0
    while IFS= read -r line; do
      [ "$line" = "$program" ] && count=$((count + 1))
    done < "$PROCESS_LOG"
    [ "$count" -eq 0 ] || printf '%s=%s ' "$program" "$count"
  done
}
run_guard() {
  local payload="$1" enabled_rc="${2:-0}" jq_crlf="${3:-0}" rc=0
  : > "$PROCESS_LOG"
  printf '%s' "$payload" | PATH="$BIN" HQ_ROOT="$TMP/root" CLAUDE_PROJECT_DIR="$TMP/root" \
    HQ_CHECKPOINT_RUNTIME=claude HQ_TEST_MONITOR_ENABLED_RC="$enabled_rc" \
    HQ_TEST_JQ_CRLF="$jq_crlf" HQ_TEST_REAL_JQ="$REAL_JQ" \
    "$BASH_BIN" "$HOOK" > "$TMP/stdout" 2> "$TMP/stderr" || rc=$?
  GUARD_RC="$rc"
}

[ -f "$HOOK" ] || { echo "FAIL: missing hook $HOOK" >&2; exit 1; }
run_guard '{"tool_input":{"command":"git status","run_in_background":false}}'
normal_total="$(total_launches)"
printf 'ordinary PreToolUse execve_total=%s inventory=%s\n' "$normal_total" "$(print_inventory)"
if [ "$GUARD_RC" -eq 0 ] && [ "$normal_total" -le 1 ] \
   && [ ! -s "$TMP/stdout" ] && [ ! -s "$TMP/stderr" ]; then
  pass 'ordinary Claude PreToolUse parses once and remains silent'
else
  fail "ordinary PreToolUse launch budget exceeded 1 or behavior changed (rc=$GUARD_RC, launches=$normal_total)"
fi

run_guard '{"tool_input":{"command":"sleep 45","run_in_background":false}}'
blocked_total="$(total_launches)"
printf 'blocking PreToolUse execve_total=%s inventory=%s\n' "$blocked_total" "$(print_inventory)"
if [ "$GUARD_RC" -eq 0 ] && [ "$blocked_total" -le 3 ] \
   && jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("sleep 45"))' "$TMP/stdout" >/dev/null; then
  pass 'a blocking wait remains denied within the total launch budget'
else
  fail "blocking PreToolUse launch budget exceeded 3 or gate behavior changed (rc=$GUARD_RC, launches=$blocked_total)"
fi

run_guard '{"tool_input":{"command":"sleep 29.9","run_in_background":false}}'
if [ "$GUARD_RC" -eq 0 ] && [ ! -s "$TMP/stdout" ] && [ "$(total_launches)" -eq 1 ]; then
  pass 'fractional waits below 30 seconds remain allowed'
else
  fail 'fractional waits below 30 seconds changed behavior'
fi

run_guard '{"tool_input":{"command":"sleep 45","run_in_background":"true"}}'
if [ "$GUARD_RC" -eq 0 ] && [ ! -s "$TMP/stdout" ] && [ "$(total_launches)" -eq 1 ]; then
  pass 'background marker coercion preserves the existing exemption'
else
  fail 'background marker exemption changed behavior'
fi

run_guard '{"tool_input":{"command":"sleep 45","run_in_background":true}}' 0 1
if [ "$GUARD_RC" -eq 0 ] && [ ! -s "$TMP/stdout" ] && [ ! -s "$TMP/stderr" ]; then
  pass 'background marker exemption survives Windows CRLF jq output'
else
  fail 'background marker exemption fails with Windows CRLF jq output'
fi

for command_text in 'sleep 30.0' 'sleep 00030' 'sleep 999999999999999999999999'; do
  command_json="$(jq -cn --arg command "$command_text" '{tool_input:{command:$command,run_in_background:false}}')"
  run_guard "$command_json"
  if [ "$GUARD_RC" -eq 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null; then
    pass "$command_text remains blocked"
  else
    fail "$command_text was not blocked"
  fi
done

disabled_payload='{"tool_input":{"command":"sleep 45","run_in_background":false}}'
run_guard "$disabled_payload" 1
disabled_first_total="$(total_launches)"
printf 'monitor-disabled first probe execve_total=%s inventory=%s\n' "$disabled_first_total" "$(print_inventory)"
if [ "$GUARD_RC" -eq 0 ] && [ ! -s "$TMP/stdout" ] \
   && [ "$(total_launches)" -le 7 ]; then
  pass 'the first disabled-monitor probe fails open within the launch budget'
else
  fail "the first disabled-monitor probe changed behavior (rc=$GUARD_RC, launches=$disabled_first_total)"
fi

run_guard "$disabled_payload" 1
disabled_warm_total="$(total_launches)"
printf 'monitor-disabled cached probe execve_total=%s inventory=%s\n' "$disabled_warm_total" "$(print_inventory)"
if [ "$GUARD_RC" -eq 0 ] && [ ! -s "$TMP/stdout" ] && [ "$disabled_warm_total" -le 2 ]; then
  pass 'the cached CLI readiness probe avoids a second hq launch'
else
  fail "the cached disabled-monitor probe exceeded 2 launches or changed behavior (rc=$GUARD_RC, launches=$disabled_warm_total)"
fi

exit "$FAIL"
