#!/usr/bin/env bash
# Warm UserPromptSubmit monitor-cache reads must stay below a deterministic jq budget.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
SCRIPT="$HQ_SRC/core/scripts/lib/lanes-senior-monitor.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -f "$SCRIPT" ] || fail "monitor script is missing"

ROOT="$TMP/hq"
BIN="$TMP/bin"
SHIMS="$TMP/shims"
COUNT="$TMP/jq-count"
REAL_JQ="$(command -v jq)"
mkdir -p "$ROOT/core/scripts/lib" "$BIN" "$SHIMS" "$TMP/cache/hq-cli/lanes-senior-monitor"
cp "$SCRIPT" "$ROOT/core/scripts/lib/lanes-senior-monitor.sh"

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
  PATH="$SHIMS:$BIN:/usr/bin:/bin" \
  bash "$ROOT/core/scripts/lib/lanes-senior-monitor.sh" UserPromptSubmit 2>"$TMP/hook.err")"
[ -z "$OUTPUT" ] || fail "empty warm cache unexpectedly emitted output"

JQ_COUNT="$(wc -c < "$COUNT" | tr -d '[:space:]')"
[ "$JQ_COUNT" -le 7 ] \
  || fail "warm cache with no active lanes launched $JQ_COUNT jq processes (budget: 7)"
printf 'PASS: warm no-lanes cache used %s jq processes (budget 7)\n' "$JQ_COUNT"
