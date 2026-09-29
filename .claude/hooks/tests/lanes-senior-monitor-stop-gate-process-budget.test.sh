#!/usr/bin/env bash
# Portable PATH-shim exec inventory for the Stop gate; no strace dependency.
set -uo pipefail
unset HQ_LANE_ID

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
SOURCE_ROOT="${HQ_TEST_SOURCE_ROOT:-$DEFAULT_ROOT}"
HOOK="${HQ_TEST_STOP_HOOK:-$SOURCE_ROOT/.claude/hooks/lanes-senior-monitor-stop-gate.sh}"
BASH_BIN="$(command -v bash)"
ORIGINAL_PATH="$PATH"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/root/.claude/hooks"
: > "$TMP/process.log"
export PROCESS_LOG="$TMP/process.log"
printf '#!/bin/bash\n' > "$TMP/root/.claude/hooks/hook-gate.sh"

# Keep PATH to the shim directory while the hook runs. Each shim logs one
# process launch and execs the real program by its absolute path.
for program in jq cat tr env timeout gtimeout perl sleep mktemp rm head dirname awk grep stat cksum date; do
  real="$(PATH="$ORIGINAL_PATH" command -v "$program" 2>/dev/null || true)"
  [ -n "$real" ] || continue
  printf -v real_q '%q' "$real"
  printf '#!/bin/bash\nprintf "%%s\\n" "%s" >> "$PROCESS_LOG"\nexec %s "$@"\n' \
    "$program" "$real_q" > "$BIN/$program"
  chmod 700 "$BIN/$program"
done
cat > "$BIN/hq" <<'SH'
#!/bin/bash
printf '%s\n' hq >> "$PROCESS_LOG"
if [ "${HQ_TEST_REMOVE_ERR_CAPTURE:-false}" = true ]; then
  for capture in "${TMPDIR:-/tmp}"/hq-lanes-monitor-check.*; do
    [ -f "$capture" ] && rm -f "$capture"
  done
fi
if [ "${1:-}" = monitor ] && [ "${2:-}" = enabled ]; then
  exit 0
fi
printf '%s\n' '{"ok":true,"action":"monitor-check","session_id":"budget-session","engine":"claude","active_lane_ids":[],"covered_lane_ids":[],"uncovered_lane_ids":[],"monitor_calls":[]}'
SH
chmod 700 "$BIN/hq"

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
  for program in jq cat tr env timeout gtimeout perl sleep mktemp rm head dirname awk grep stat cksum date hq; do
    count=0
    while IFS= read -r line; do
      [ "$line" = "$program" ] && count=$((count + 1))
    done < "$PROCESS_LOG"
    [ "$count" -eq 0 ] || printf '%s=%s ' "$program" "$count"
  done
}
run_stop() {
  local rc=0 payload='{"session_id":"budget-session","engine":"claude"}'
  : > "$PROCESS_LOG"
  printf '%s' "$payload" | PATH="$BIN" HQ_LANE_ID=lead-lane-1 HQ_ROOT="$TMP/root" \
    CLAUDE_PROJECT_DIR="$TMP/root" TMPDIR="$TMP" "$BASH_BIN" "$HOOK" \
    > "$TMP/stdout" 2> "$TMP/stderr" || rc=$?
  STOP_RC="$rc"
}
run_stop_with_missing_capture() {
  local rc=0 payload='{"session_id":"budget-session","engine":"claude"}'
  : > "$PROCESS_LOG"
  printf '%s' "$payload" | PATH="$BIN" HQ_LANE_ID=lead-lane-1 HQ_ROOT="$TMP/root" \
    CLAUDE_PROJECT_DIR="$TMP/root" TMPDIR="$TMP" HQ_TEST_REMOVE_ERR_CAPTURE=true \
    "$BASH_BIN" "$HOOK" > "$TMP/stdout" 2> "$TMP/stderr" || rc=$?
  STOP_RC="$rc"
}
run_stop_with_closed_stdin() {
  local rc=0
  : > "$PROCESS_LOG"
  PATH="$BIN" HQ_LANE_ID=lead-lane-1 HQ_ROOT="$TMP/root" \
    CLAUDE_PROJECT_DIR="$TMP/root" TMPDIR="$TMP" "$BASH_BIN" "$HOOK" \
    <&- > "$TMP/stdout" 2> "$TMP/stderr" || rc=$?
  STOP_RC="$rc"
}
program_count() {
  local expected="$1" count=0 line
  while IFS= read -r line; do
    [ "$line" = "$expected" ] && count=$((count + 1))
  done < "$PROCESS_LOG"
  printf '%s' "$count"
}

[ -f "$HOOK" ] || { echo "FAIL: missing hook $HOOK" >&2; exit 1; }
run_stop
senior_total="$(total_launches)"
senior_hq_calls="$(program_count hq)"
printf 'senior (HQ_LANE_ID set) execve_total=%s inventory=%s\n' "$senior_total" "$(print_inventory)"
if [ "$STOP_RC" -eq 0 ] && [ ! -s "$TMP/stdout" ] && [ ! -s "$TMP/stderr" ]; then
  pass 'a senior session still performs the monitor-check and passes cleanly'
else
  fail "senior monitor-check pass behavior changed (rc=$STOP_RC stdout=$(cat "$TMP/stdout") stderr=$(cat "$TMP/stderr"))"
fi
if [ "$senior_hq_calls" -eq 1 ]; then
  pass 'a lead session with HQ_LANE_ID still invokes the senior monitor-check'
else
  fail "a lead session with HQ_LANE_ID must invoke monitor-check once (calls=$senior_hq_calls)"
fi
if [ "$senior_total" -le 6 ]; then
  pass 'the total senior Stop-hook launch budget is at most 6'
else
  fail "senior Stop-hook launch budget exceeded 6: $senior_total"
fi

run_stop_with_closed_stdin
closed_stdin_err="$(<"$TMP/stderr")"
case "$closed_stdin_err" in
  *"/dev/stdin"*|*"No such file"*) fail "closed stdin emitted a redirection diagnostic: $closed_stdin_err" ;;
  *) pass 'closed stdin is drained without a redirection diagnostic' ;;
esac

run_stop_with_missing_capture
missing_capture_err="$(<"$TMP/stderr")"
if [ "$STOP_RC" -eq 0 ] && [ ! -s "$TMP/stdout" ] \
   && [ -z "$missing_capture_err" ]; then
  pass 'a missing hq stderr capture file stays silent'
else
  fail "missing hq stderr capture changed the passing hook result (rc=$STOP_RC stdout=$(cat "$TMP/stdout") stderr=$missing_capture_err)"
fi

exit "$FAIL"
