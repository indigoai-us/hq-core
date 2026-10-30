#!/usr/bin/env bash
# The monitor guard must handle a large command quickly under bash 3.2 and
# bash 5, with LF and CRLF line endings. It used to normalize and join the
# command with ${text//$'\r\n'/$'\n'} and ${flat//$'\n'/ }, which grow
# quadratically on bash 3.2 (a 96 KB command ran for about 110 s), and split
# the jq fields with ${parsed_fields%%$'\x1f'*}, which took about 7 s on bash 5.
set -uo pipefail
unset HQ_LANE_ID

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
HOOK="${HQ_TEST_MONITOR_GUARD_HOOK:-$ROOT/.claude/hooks/hq-monitor-guard.sh}"
BASH_BIN="$(command -v bash)"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$HOOK" ] || { echo "FAIL: missing hook $HOOK" >&2; exit 1; }

# Windows bash reads a here-string one byte per read() call, so the line loop
# is slower there. The budget still fails the quadratic code by a wide margin.
case "${OSTYPE:-}" in
  msys*|cygwin*) BUDGET="${HQ_TEST_MONITOR_LARGE_BUDGET:-20}" ;;
  *) BUDGET="${HQ_TEST_MONITOR_LARGE_BUDGET:-3}" ;;
esac
KILL_AFTER=$((BUDGET * 2))

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/root/.claude/hooks"
printf '#!/bin/bash\n' > "$TMP/root/.claude/hooks/hook-gate.sh"
cat > "$TMP/bin/hq" <<'SH'
#!/bin/bash
if [ "${1:-}" = monitor ] && [ "${2:-}" = enabled ]; then exit 0; fi
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Usage: hq [command]' '  monitor  Monitor session events'
fi
exit 0
SH
chmod 700 "$TMP/bin/hq"
touch -t 200001010000 "$TMP/bin/hq"

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

FAIL=0
pass() { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

# run_guard <payload-file>: sets GUARD_RC, GUARD_SECS, GUARD_KILLED.
run_guard() {
  local start end pid watchdog
  : > "$TMP/stdout"
  start="$(now)"
  PATH="$TMP/bin:$PATH" HQ_ROOT="$TMP/root" CLAUDE_PROJECT_DIR="$TMP/root" \
    HQ_CHECKPOINT_RUNTIME=claude "$BASH_BIN" "$HOOK" < "$1" > "$TMP/stdout" 2> "$TMP/stderr" &
  pid=$!
  ( sleep "$KILL_AFTER"; kill -9 "$pid" 2>/dev/null && : > "$TMP/killed" ) &
  watchdog=$!
  rm -f "$TMP/killed"
  GUARD_RC=0
  wait "$pid" || GUARD_RC=$?
  end="$(now)"
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  GUARD_KILLED=0
  [ ! -e "$TMP/killed" ] || GUARD_KILLED=1
  GUARD_SECS="$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f", e - s }')"
}

within_budget() { awk -v s="$GUARD_SECS" -v b="$BUDGET" 'BEGIN { exit !(s < b) }'; }
denied() { jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null 2>&1; }

# write_payload <eol> <name> <prefix> <body-line> <suffix>: 4000 body lines.
write_payload() {
  local eol="$1" name="$2" prefix="$3" body_line="$4" suffix="$5"
  # Each body line is "<body-line> <n>" with the chosen line ending.
  {
    printf '%s' "$prefix"
    awk -v pre="$body_line" -v eol="$eol" 'BEGIN { for (i = 1; i <= 4000; i++) printf "%s %07d%s", pre, i, eol }'
    printf '%s' "$suffix"
  } > "$TMP/$name.cmd"
  jq -n --rawfile c "$TMP/$name.cmd" \
    '{tool_name:"Bash",session_id:"s",tool_input:{command:$c,run_in_background:false}}' > "$TMP/$name.json"
}

check() {
  local label="$1" name="$2" expect="$3" bytes
  bytes="$(wc -c < "$TMP/$name.cmd" | tr -d ' ')"
  run_guard "$TMP/$name.json"
  printf 'timing: %s bytes=%s secs=%s budget=%s\n' "$label" "$bytes" "$GUARD_SECS" "$BUDGET"
  if [ "$GUARD_KILLED" -eq 1 ]; then
    fail "$label: killed after ${KILL_AFTER}s"
    return
  fi
  if ! within_budget; then
    fail "$label: took ${GUARD_SECS}s, budget ${BUDGET}s"
    return
  fi
  if [ "$expect" = deny ]; then
    if [ "$GUARD_RC" -eq 0 ] && denied; then pass "$label: denied in ${GUARD_SECS}s"
    else fail "$label: expected deny (rc=$GUARD_RC)"; fi
  else
    if [ "$GUARD_RC" -eq 0 ] && [ ! -s "$TMP/stdout" ]; then pass "$label: allowed in ${GUARD_SECS}s"
    else fail "$label: expected allow (rc=$GUARD_RC)"; fi
  fi
}

for mode in lf crlf; do
  eol='\n'
  [ "$mode" = lf ] || eol='\r\n'
  nl=$'\n'
  [ "$mode" = lf ] || nl=$'\r\n'

  write_payload "$eol" "$mode-plain" '' 'echo x && true &&' ''
  check "$mode 4000-line command with no wait" "$mode-plain" allow

  # No shell operators, so the hq monitor exemption check reads every byte.
  write_payload "$eol" "$mode-tail" '' 'echo x' "sleep 45$nl"
  check "$mode 4000-line command ending in sleep 45" "$mode-tail" deny

  write_payload "$eol" "$mode-monitor" "hq monitor start --command 'until true; do sleep 30; done' --description '" 'note' "'$nl"
  check "$mode 4000-line hq monitor command" "$mode-monitor" allow

  # A long heredoc body is data. Its delimiter line still closes the heredoc
  # when it ends in CR, so a later wait is still seen.
  write_payload "$eol" "$mode-heredoc" "cat > /tmp/notes <<'EOF'$nl" 'sleep 45 #' "EOF${nl}echo done$nl"
  check "$mode heredoc body with sleep text only" "$mode-heredoc" allow

  write_payload "$eol" "$mode-heredoc-tail" "cat > /tmp/notes <<'EOF'$nl" 'note' "EOF${nl}sleep 31$nl"
  check "$mode heredoc followed by sleep 31" "$mode-heredoc-tail" deny
done

exit "$FAIL"
