#!/usr/bin/env bash
# hq-core: public
# Table test for cron_to_oncalendar in core/scripts/outpost-jobs-reconcile.sh.
# Every supported cron form must map to an exact systemd OnCalendar value, the
# timezone suffix must survive, and unsupported forms must fail rather than
# widen. When systemd-analyze is on PATH (Linux CI), each rendered value is
# also checked with `systemd-analyze calendar`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RECON="$ROOT/core/scripts/outpost-jobs-reconcile.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$RECON" ] || fail "missing $RECON"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/outpost-cron-oncalendar.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

awk 'BEGIN{p=0} /^# --- cron → systemd OnCalendar/{p=1} /^# --- unit writers/{exit} p{print}' \
  "$RECON" >"$TMP/cron-fns.sh"
grep -q '^cron_to_oncalendar()' "$TMP/cron-fns.sh" || fail "cron_to_oncalendar not found in $RECON"
cat >>"$TMP/cron-fns.sh" <<'EOF'
set -f
# shellcheck disable=SC2086
set -- $1
set +f
cron_to_oncalendar "$@"
EOF

render() { bash "$TMP/cron-fns.sh" "$1"; }

ANALYZE=""
if command -v systemd-analyze >/dev/null 2>&1; then
  ANALYZE="$(command -v systemd-analyze)"
elif [ "${OUTPOST_CRON_REQUIRE_SYSTEMD_ANALYZE:-0}" = 1 ]; then
  fail "OUTPOST_CRON_REQUIRE_SYSTEMD_ANALYZE=1 but systemd-analyze is not on PATH"
fi

CHECKED=0
expect() {
  local cron="$1" expected="$2" tz="${3:-}" actual full
  actual="$(render "$cron" 2>"$TMP/err")" || fail "'$cron' failed: $(cat "$TMP/err")"
  [ "$actual" = "$expected" ] || fail "'$cron' rendered '$actual', expected '$expected'"
  full="$actual${tz:+ $tz}"
  if [ -n "$ANALYZE" ]; then
    "$ANALYZE" calendar "$full" >"$TMP/analyze" 2>&1 \
      || fail "systemd-analyze calendar rejected '$full': $(cat "$TMP/analyze")"
    CHECKED=$((CHECKED + 1))
  fi
  pass "$cron -> $full"
}

expect_error() {
  local cron="$1" actual
  if actual="$(render "$cron" 2>"$TMP/err")"; then
    fail "'$cron' must fail, rendered '$actual'"
  fi
  grep -q 'cron_to_oncalendar:' "$TMP/err" || fail "'$cron' failed without a reason on stderr"
  [ -z "$actual" ] || fail "'$cron' printed '$actual' while failing"
  pass "$cron -> error ($(head -n1 "$TMP/err"))"
}

TZ_LA='America/Los_Angeles'

# The reported bug: the 7-19 hour range must survive the step.
expect '0 7-19/2 * * 1-5' 'Mon..Fri *-*-* 07..19/2:00:00' "$TZ_LA"
expect '30 8 * * 1-5' 'Mon..Fri *-*-* 08:30:00' "$TZ_LA"
expect '*/15 * * * *' '*-*-* *:00/15:00'
expect '0 0 1 * *' '*-*-01 00:00:00'
expect '0 9-17 * * 1-5' 'Mon..Fri *-*-* 09..17:00:00' "$TZ_LA"

# Minute field.
expect '* 9 * * *' '*-*-* 09:00:00'
expect '5 9 * * *' '*-*-* 09:05:00'
expect '0,30 9 * * *' '*-*-* 09:00,30:00'
expect '0-30 9 * * *' '*-*-* 09:00..30:00'
expect '10-50/20 9 * * *' '*-*-* 09:10..50/20:00'
expect '5/20 9 * * *' '*-*-* 09:05/20:00'
expect '1,5-7,40-59/10 9 * * *' '*-*-* 09:01,05..07,40..59/10:00'

# Hour field.
expect '0 */6 * * *' '*-*-* 00/6:00:00'
expect '0 1,5-7 * * *' '*-*-* 01,05..07:00:00'
expect '15 8,12,18 * * *' '*-*-* 08,12,18:15:00'
expect '0 9/3 * * *' '*-*-* 09/3:00:00'
expect '0 0-23/4 * * *' '*-*-* 00..23/4:00:00'
expect '0 7-19/2 * * *' '*-*-* 07..19/2:00:00' "$TZ_LA"

# Day-of-month field.
expect '0 6 1,15 * *' '*-*-01,15 06:00:00'
expect '0 6 1-7 * *' '*-*-01..07 06:00:00'
expect '0 6 */10 * *' '*-*-01/10 06:00:00'
expect '0 6 5-25/5 * *' '*-*-05..25/5 06:00:00'

# Month field.
expect '0 0 1 1 *' '*-01-01 00:00:00'
expect '0 0 1 */3 *' '*-01/3-01 00:00:00'
expect '0 0 1 3-9/2 *' '*-03..09/2-01 00:00:00'
expect '0 0 1 1,6,12 *' '*-01,06,12-01 00:00:00'
expect '0 12 * 6-8 1-5' 'Mon..Fri *-06..08-* 12:00:00' "$TZ_LA"

# Day-of-week field: 0 and 7 are Sunday, ranges, lists, steps, names.
expect '0 9 * * 0' 'Sun *-*-* 09:00:00'
expect '0 9 * * 7' 'Sun *-*-* 09:00:00'
expect '0 9 * * 1' 'Mon *-*-* 09:00:00'
expect '0 9 * * 6' 'Sat *-*-* 09:00:00'
expect '0 9 * * 0,6' 'Sat,Sun *-*-* 09:00:00'
expect '0 9 * * 6,7' 'Sat,Sun *-*-* 09:00:00'
expect '0 9 * * 1,3,5' 'Mon,Wed,Fri *-*-* 09:00:00'
expect '0 9 * * 1-3,5' 'Mon..Wed,Fri *-*-* 09:00:00'
expect '0 9 * * 5-7' 'Fri..Sun *-*-* 09:00:00'
expect '0 9 * * 0-2' 'Mon,Tue,Sun *-*-* 09:00:00'
expect '0 9 * * 1-2' 'Mon,Tue *-*-* 09:00:00'
expect '0 9 * * 1-5/2' 'Mon,Wed,Fri *-*-* 09:00:00'
expect '0 9 * * */2' 'Tue,Thu,Sat,Sun *-*-* 09:00:00'
expect '0 9 * * 1/2' 'Mon,Wed,Fri *-*-* 09:00:00'
expect '0 9 * * 0-7' '*-*-* 09:00:00'
expect '0 9 * * 0-6' '*-*-* 09:00:00'
expect '0 9 * * mon-fri' 'Mon..Fri *-*-* 09:00:00'
expect '0 9 * * SAT,SUN' 'Sat,Sun *-*-* 09:00:00'

# Unsupported forms must fail loudly, never widen.
expect_error '0 9 1 * 1'        # dom and dow both restricted (cron ORs them)
expect_error '0 9 L * *'        # last-day-of-month
expect_error '0 9 * * 1#2'      # nth weekday
expect_error '0 9 ? * 1'        # Quartz-style ?
expect_error '0 9 * JAN *'      # month names
expect_error '0 9-7 * * *'      # reversed range
expect_error '0 9 * * 5-1'      # reversed weekday range
expect_error '60 9 * * *'       # minute out of range
expect_error '0 24 * * *'       # hour out of range
expect_error '0 9 0 * *'        # day-of-month out of range
expect_error '0 9 * 13 *'       # month out of range
expect_error '0 9 * * 8'        # weekday out of range
expect_error '0 */0 * * *'      # zero step
expect_error '0 1,*,3 * * *'    # '*' inside a list
expect_error '0 1,,3 * * *'     # empty list item
expect_error '0 1/2/3 * * *'    # double step
expect_error '0 9 * *'          # four fields
expect_error '@daily'           # macro

if [ -n "$ANALYZE" ]; then
  pass "systemd-analyze calendar accepted $CHECKED rendered values"
else
  echo "  note: systemd-analyze not on PATH; skipped systemd-analyze calendar checks"
fi

echo "ALL PASSED (outpost-cron-oncalendar)"
