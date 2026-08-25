#!/usr/bin/env bash
# hq-core: public
# Regression: jobs-schedule-parse.sh NL → cron (US-003).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PARSE="$ROOT/core/scripts/jobs-schedule-parse.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 0; }
[ -f "$PARSE" ] || { echo "FAIL: missing $PARSE" >&2; exit 1; }
[ -x "$PARSE" ] || chmod +x "$PARSE"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

parse_field() {
  # parse_field <json> <key>
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" '.[$k] // empty' <<<"$1"
  else
    node -e 'const d=JSON.parse(process.argv[1]); const v=d[process.argv[2]]; process.stdout.write(v==null?"":String(v))' "$1" "$2"
  fi
}

echo "[1] weekday NL → cron"
out="$("$PARSE" --tz America/New_York "every weekday at 9am")"
echo "$out" | grep -q '"ok":true' || fail "expected ok: $out"
[ "$(parse_field "$out" cron)" = "0 9 * * 1-5" ] || fail "cron: $out"
[ "$(parse_field "$out" timezone)" = "America/New_York" ] || fail "tz: $out"
echo "$out" | grep -qi 'weekday' || fail "human should mention weekday: $out"
pass "every weekday at 9am"

echo "[2] daily with minutes"
out="$("$PARSE" --tz America/Los_Angeles "every day at 14:30")"
[ "$(parse_field "$out" cron)" = "30 14 * * *" ] || fail "cron: $out"
pass "every day at 14:30"

echo "[3] raw cron passthrough"
out="$("$PARSE" --tz UTC "*/15 * * * *")"
[ "$(parse_field "$out" cron)" = "*/15 * * * *" ] || fail "cron: $out"
[ "$(parse_field "$out" source)" = "cron" ] || fail "source: $out"
pass "raw cron"

echo "[4] monday NL"
out="$("$PARSE" --tz UTC "every monday at 9:00am")"
[ "$(parse_field "$out" cron)" = "0 9 * * 1" ] || fail "cron: $out"
pass "every monday at 9:00am"

echo "[5] every N minutes"
out="$("$PARSE" --tz UTC "every 15 minutes")"
[ "$(parse_field "$out" cron)" = "*/15 * * * *" ] || fail "cron: $out"
pass "every 15 minutes"

echo "[6] unrecognized NL fails"
rc=0
err="$("$PARSE" --tz UTC "sometime soon maybe" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "expected non-zero for garbage NL"
echo "$err" | grep -q '"ok":false' || fail "expected ok false: $err"
pass "garbage NL rejected"

echo "[7] empty rejected"
rc=0
"$PARSE" --tz UTC "   " >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "empty should fail"
pass "empty rejected"

echo "[8] mon-fri cron alias"
out="$("$PARSE" --tz UTC "0 8 * * Mon-Fri")"
[ "$(parse_field "$out" cron)" = "0 8 * * 1-5" ] || fail "cron: $out"
pass "Mon-Fri normalized"

echo "PASS: jobs-schedule-parse"
