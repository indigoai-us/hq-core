#!/usr/bin/env bash
# Warm UserPromptSubmit monitor-cache reads must stay below a deterministic jq budget.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
SCRIPT="$HQ_SRC/core/scripts/lib/lanes-senior-monitor.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || fail "node is required for the bounded hook runner"
NODE_DIR="$(dirname "$NODE_BIN")"
[ -f "$SCRIPT" ] || fail "monitor script is missing"

ROOT="$TMP/hq"
BIN="$TMP/bin"
SHIMS="$TMP/shims"
COUNT="$TMP/jq-count"
REAL_JQ="$(command -v jq)"
mkdir -p "$ROOT/core/scripts/lib" "$BIN" "$SHIMS" "$TMP/cache/hq-cli/lanes-senior-monitor"
cp "$SCRIPT" "$ROOT/core/scripts/lib/lanes-senior-monitor.sh"
cp "$HQ_SRC/core/scripts/lib/session-auto-bind.sh" "$ROOT/core/scripts/lib/session-auto-bind.sh"

cat > "$BIN/hq" <<'SH'
#!/usr/bin/env bash
echo "unexpected monitor-check; the valid warm cache should be sufficient" >&2
exit 70
SH
cat > "$SHIMS/jq" <<'SH'
#!/usr/bin/env bash
printf x >> "$HQ_TEST_JQ_COUNT"
exec "$HQ_TEST_REAL_JQ" "$@"
SH
chmod +x "$BIN/hq" "$SHIMS/jq"

SESSION="monitor-cache-budget-$$"
FINGERPRINT="$(cksum "$BIN/hq" | awk 'NF >= 2 { print $1 "-" $2; exit }')"
NOW="$(date +%s)"
RESULT="$("$REAL_JQ" -cn --arg sid "$SESSION" \
  '{action:"monitor-check",session_id:$sid,engine:"claude",active_lane_ids:[],uncovered_lane_ids:[]}')"
"$REAL_JQ" -cn --arg sid "$SESSION" --arg fingerprint "$FINGERPRINT" \
  --argjson checked_at_epoch "$NOW" --argjson result "$RESULT" --arg reminder '' \
  '{schema:1,session_id:$sid,engine:"claude",hq_fingerprint:$fingerprint,checked_at_epoch:$checked_at_epoch,result:$result,reminder:$reminder}' \
  > "$TMP/cache/hq-cli/lanes-senior-monitor/$SESSION.$FINGERPRINT.monitor.json"
PAYLOAD="$("$REAL_JQ" -cn --arg sid "$SESSION" '{session_id:$sid,engine:"claude"}')"

: > "$COUNT"
OUTPUT="$(printf '%s' "$PAYLOAD" | env \
  HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" HOME="$TMP/home" \
  XDG_CACHE_HOME="$TMP/cache" HQ_TEST_JQ_COUNT="$COUNT" HQ_TEST_REAL_JQ="$REAL_JQ" \
  PATH="$SHIMS:$BIN:$NODE_DIR:/usr/bin:/bin" \
  bash "$ROOT/core/scripts/lib/lanes-senior-monitor.sh" UserPromptSubmit 2>"$TMP/hook.err")"
[ -z "$OUTPUT" ] || fail "empty warm cache unexpectedly emitted output"

JQ_COUNT="$(wc -c < "$COUNT" | tr -d '[:space:]')"
[ "$JQ_COUNT" -le 7 ] \
  || fail "warm cache with no active lanes launched $JQ_COUNT jq processes (budget: 7)"
printf 'PASS: warm no-lanes cache used %s jq processes (budget 7)\n' "$JQ_COUNT"

# A cold UserPromptSubmit cache can invoke monitor-check. Give this advisory
# hook enough time for a warm CLI startup, while keeping it within the hook.
cat > "$BIN/hq" <<'SH'
#!/usr/bin/env bash
session=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--session" ]; then session="$2"; shift 2; else shift; fi
done
sleep "${HQ_STUB_DELAY:-0}"
printf done > "$HQ_STUB_MARKER"
printf '{"action":"monitor-check","session_id":"%s","engine":"claude","active_lane_ids":[],"uncovered_lane_ids":[]}\n' "$session"
SH
chmod +x "$BIN/hq"

cache_exists() {
  compgen -G "$TMP/cache/hq-cli/lanes-senior-monitor/$1.*.monitor.json" >/dev/null
}
run_hook() {
  local event="$1" sid="$2" delay="$3" marker="$4" err="$5" payload rc=0
  payload="$("$REAL_JQ" -cn --arg sid "$sid" '{session_id:$sid,engine:"claude"}')"
  printf '%s' "$payload" | env \
    HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" HOME="$TMP/home" \
    XDG_CACHE_HOME="$TMP/cache" HQ_TEST_JQ_COUNT="$COUNT" HQ_TEST_REAL_JQ="$REAL_JQ" \
    HQ_STUB_DELAY="$delay" HQ_STUB_MARKER="$marker" \
    PATH="$SHIMS:$BIN:$NODE_DIR:/usr/bin:/bin" \
    bash "$ROOT/core/scripts/lib/lanes-senior-monitor.sh" "$event" 2>"$err" || rc=$?
  return "$rc"
}

# (a) A stalled UserPromptSubmit lookup is killed at its explicit 8 s bound.
SLOW_SESSION="monitor-user-prompt-stall-$$"
SLOW_MARKER="$TMP/user-prompt-stall.done"
SLOW_ERR="$TMP/user-prompt-stall.err"
set +e
run_hook UserPromptSubmit "$SLOW_SESSION" 12 "$SLOW_MARKER" "$SLOW_ERR"
SLOW_RC=$?
set -e
[ "$SLOW_RC" -eq 0 ] || fail "stalled UserPromptSubmit did not exit quietly (exit $SLOW_RC)"
[ ! -s "$SLOW_ERR" ] || fail "stalled UserPromptSubmit wrote stderr: $(cat "$SLOW_ERR")"
[ ! -e "$SLOW_MARKER" ] || fail 'stalled UserPromptSubmit child ran past its timeout'
! cache_exists "$SLOW_SESSION" || fail 'stalled UserPromptSubmit wrote a cache entry on timeout'
printf 'PASS: stalled UserPromptSubmit is killed at 8 s, exits 0, and writes no stderr or cache\n'

# (b) UserPromptSubmit has room for a 3 s warm CLI startup and caches success.
WARM_SESSION="monitor-user-prompt-warm-$$"
WARM_MARKER="$TMP/user-prompt-warm.done"
WARM_ERR="$TMP/user-prompt-warm.err"
run_hook UserPromptSubmit "$WARM_SESSION" 3 "$WARM_MARKER" "$WARM_ERR" \
  || fail '3 s UserPromptSubmit monitor-check did not succeed'
[ -e "$WARM_MARKER" ] || fail '3 s UserPromptSubmit child did not finish'
[ ! -s "$WARM_ERR" ] || fail "successful UserPromptSubmit wrote stderr: $(cat "$WARM_ERR")"
cache_exists "$WARM_SESSION" || fail 'successful UserPromptSubmit did not persist its cache entry'
printf 'PASS: 3 s UserPromptSubmit succeeds and caches the result\n'

# A timed-out --reminder lookup is advisory too. The JSON monitor-check must
# succeed first, then the reminder child must exceed the UserPromptSubmit bound.
cat > "$BIN/hq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
session=""
engine="claude"
previous_arg=""
for current_arg in "$@"; do
  if [ "$previous_arg" = "--session" ]; then session="$current_arg"; fi
  if [ "$previous_arg" = "--engine" ]; then engine="$current_arg"; fi
  previous_arg="$current_arg"
done
if [ "${3:-}" = "--reminder" ]; then
  sleep 12
  printf 'late reminder output must not escape\n'
  exit 0
fi
printf '{"action":"monitor-check","session_id":"%s","engine":"%s","active_lane_ids":["lane-a"],"uncovered_lane_ids":["lane-a"]}\n' "$session" "$engine"
exit 2
SH
chmod +x "$BIN/hq"
REMINDER_SESSION="monitor-user-prompt-reminder-stall-$$"
REMINDER_ERR="$TMP/user-prompt-reminder-stall.err"
REMINDER_RC=0
REMINDER_OUTPUT="$(run_hook UserPromptSubmit "$REMINDER_SESSION" 0 \
  "$TMP/user-prompt-reminder-stall.done" "$REMINDER_ERR")" || REMINDER_RC=$?
[ "$REMINDER_RC" -eq 0 ] || fail "timed-out UserPromptSubmit reminder did not exit quietly (exit $REMINDER_RC)"
[ -z "$REMINDER_OUTPUT" ] || fail "timed-out UserPromptSubmit reminder wrote stdout: $REMINDER_OUTPUT"
[ ! -s "$REMINDER_ERR" ] || fail "timed-out UserPromptSubmit reminder wrote stderr: $(cat "$REMINDER_ERR")"
! cache_exists "$REMINDER_SESSION" || fail 'timed-out UserPromptSubmit reminder wrote a cache entry'
printf 'PASS: timed-out UserPromptSubmit reminder exits quietly and writes no cache\n'

# (c) SessionStart retains its existing 2 s bound and quiet timeout behavior.
START_SESSION="monitor-session-start-stall-$$"
START_MARKER="$TMP/session-start-stall.done"
START_ERR="$TMP/session-start-stall.err"
set +e
run_hook SessionStart "$START_SESSION" 4 "$START_MARKER" "$START_ERR"
START_RC=$?
set -e
[ "$START_RC" -eq 0 ] || fail "stalled SessionStart did not exit quietly (exit $START_RC)"
[ ! -s "$START_ERR" ] || fail "stalled SessionStart wrote stderr: $(cat "$START_ERR")"
[ ! -e "$START_MARKER" ] || fail 'SessionStart no longer uses the existing 2 s bound'
! cache_exists "$START_SESSION" || fail 'SessionStart timeout wrote a cache entry'
printf 'PASS: SessionStart retains its 2 s quiet timeout and writes no cache\n'
