#!/usr/bin/env bash
# Pins the /super-conductor work-day cadence:
#   - `super-conductor-prefs.mjs interval` returns watch_interval.present inside
#     work_hours and watch_interval.away outside them, in work_hours.timezone;
#   - days accept a range ("mon-fri") or a list, and an end before the start
#     wraps past midnight;
#   - with no work_hours in the file the default is Mon-Fri 09:00-18:00;
#   - the heartbeat's `--interval auto` resolves the cadence from the schedule
#     on every loop and names the mode on each wake line.
set -uo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
PREFS="$ROOT/core/scripts/super-conductor-prefs.mjs"
HB="$ROOT/core/scripts/super-conductor-heartbeat.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # description condition-exit-code
  if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi
}
expect() { # description expected actual
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 (expected '$2', got '$3')" >&2; fail=1; fi
}
interval_at() { SC_PREFS_FILE="$tmp/p.yaml" node "$PREFS" interval --at "$1"; }

cat >"$tmp/p.yaml" <<'EOF'
watch_interval:
  present: 120
  away: 1500
work_hours:
  timezone: America/Denver
  days: mon-fri
  start: "08:00"
  end: "18:00"
EOF

# 2026-10-19 is a Monday. Denver is UTC-6 in October (MDT).
expect "Monday 09:00 Denver is present" "120 present" "$(interval_at 2026-10-19T15:00:00Z)"
expect "Monday 07:59 Denver is away" "1500 away" "$(interval_at 2026-10-19T13:59:00Z)"
expect "Monday 18:00 Denver is away (end is exclusive)" "1500 away" "$(interval_at 2026-10-20T00:00:00Z)"
expect "Saturday noon Denver is away" "1500 away" "$(interval_at 2026-10-24T18:00:00Z)"
# 02:00Z Tuesday is still Monday 20:00 in Denver: the zone, not UTC, decides.
expect "timezone decides the day and hour" "1500 away" "$(interval_at 2026-10-20T02:00:00Z)"

# A list of days and an overnight shift.
cat >"$tmp/p.yaml" <<'EOF'
watch_interval: {present: 60, away: 900}
work_hours:
  timezone: UTC
  days: [sat, sun]
  start: "22:00"
  end: "02:00"
EOF
expect "Saturday 23:00 inside an overnight shift" "60 present" "$(interval_at 2026-10-24T23:00:00Z)"
expect "Sunday 01:00 belongs to Saturday's shift" "60 present" "$(interval_at 2026-10-25T01:00:00Z)"
expect "Monday 01:00 belongs to Sunday's shift" "60 present" "$(interval_at 2026-10-26T01:00:00Z)"
expect "Tuesday 01:00 is outside (Monday is not a work day)" "900 away" "$(interval_at 2026-10-27T01:00:00Z)"

# No work_hours: default Mon-Fri 09:00-18:00 in the given zone. Pin the zone so
# the test does not depend on the machine's.
cat >"$tmp/p.yaml" <<'EOF'
work_hours:
  timezone: UTC
EOF
expect "default schedule, Monday 10:00" "60 present" "$(interval_at 2026-10-19T10:00:00Z)"
expect "default schedule, Monday 19:00" "1500 away" "$(interval_at 2026-10-19T19:00:00Z)"

# Bad values are refused, not silently treated as present.
printf 'work_hours:\n  timezone: Mars/Olympus\n' >"$tmp/p.yaml"
set +e; interval_at 2026-10-19T10:00:00Z >/dev/null 2>&1; rc=$?; set -e
expect "unknown time zone exits 3" 3 "$rc"

# Validation (review): bad values are refused with exit 3, never guessed.
refused() { # description yaml
  printf '%s\n' "$2" >"$tmp/p.yaml"
  set +e; interval_at 2026-10-19T15:00:00Z >/dev/null 2>&1; local rc=$?; set +e
  expect "$1" 3 "$rc"
}
refused "a start hour of 24 is refused" 'work_hours: {timezone: UTC, start: "24:30", end: "18:00"}'
refused "an end past 24:00 is refused" 'work_hours: {timezone: UTC, start: "09:00", end: "24:30"}'
refused "a start equal to the end is refused" 'work_hours: {timezone: UTC, start: "09:00", end: "09:00"}'
refused "a day name that only starts like one (monkey) is refused" "$(printf 'work_hours:\n  timezone: UTC\n  days: [mon, monkey]')"
refused "a scalar work_hours is refused" 'work_hours: weekdays'
printf 'watch_interval: {present: 60, away: 900}\nwork_hours:\n  timezone: UTC\n  days: [monday, tuesday]\n  start: "09:00"\n  end: "24:00"\n' >"$tmp/p.yaml"
expect "full day names and an end of 24:00 are accepted" "60 present" "$(interval_at 2026-10-19T23:30:00Z)"
printf 'watch_interval: {present: 90.5, away: 900}\nwork_hours: {timezone: UTC}\n' >"$tmp/p.yaml"
expect "a fractional interval is rounded to whole seconds" "91 present" "$(interval_at 2026-10-19T10:00:00Z)"

# Heartbeat --interval auto: the cadence comes from the schedule. The fake
# prefs file makes "now" always inside work hours (every day, 00:00-24:00).
cat >"$tmp/p.yaml" <<'EOF'
watch_interval: {present: 1, away: 3000}
work_hours: {timezone: UTC, days: sun-sat, start: "00:00", end: "24:00"}
EOF
cat >"$tmp/hq" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$(dirname "$0")/calls"
echo '{"pending":false,"timeout":true}'; exit 3
EOF
chmod +x "$tmp/hq"
out="$(SC_PREFS_FILE="$tmp/p.yaml" HQ_BIN="$tmp/hq" SC_HEARTBEAT_MIN_INTERVAL=1 \
  bash "$HB" --interval auto --link cl-test --channels hq_dms --once)"
grep -q -- '--timeout 1' "$tmp/calls"; check "auto uses watch_interval.present inside work hours" $?
grep -q 'cadence: present 1s' <<<"$out"; check "wake line names the present cadence ($out)" $?

printf 'watch_interval: {present: 1, away: 2}\nwork_hours: {timezone: UTC, days: [], start: "09:00", end: "10:00"}\n' >"$tmp/p.yaml"
rm -f "$tmp/calls"
out="$(SC_PREFS_FILE="$tmp/p.yaml" HQ_BIN="$tmp/hq" SC_HEARTBEAT_MIN_INTERVAL=1 \
  bash "$HB" --interval auto --link cl-test --channels hq_dms --once)"
grep -q -- '--timeout 2' "$tmp/calls"; check "auto uses watch_interval.away outside work hours" $?
grep -q 'cadence: away 2s' <<<"$out"; check "wake line names the away cadence ($out)" $?

# A bad schedule is reported, not silently replaced by a default cadence.
printf 'work_hours:\n  timezone: Mars/Olympus\n' >"$tmp/p.yaml"
rm -f "$tmp/calls"
out="$(SC_PREFS_FILE="$tmp/p.yaml" HQ_BIN="$tmp/hq" SC_HEARTBEAT_MIN_INTERVAL=1 \
  bash "$HB" --interval auto --link cl-test --channels hq_dms --once)"
grep -q '^SUPER-CONDUCTOR CADENCE-ERROR .*Mars/Olympus' <<<"$out"; check "a bad work_hours value prints CADENCE-ERROR naming it ($out)" $?
check "CADENCE-ERROR is printed once ($out)" "$([[ $(grep -c CADENCE-ERROR <<<"$out") -eq 1 ]]; echo $?)"

# Skill contract: the work-day cadence, the message wake, the active-channel
# sweep, and the open-thread rule are documented where the conductor reads them.
SC="$ROOT/.claude/skills/super-conductor/SKILL.md"
need() { grep -Eq -- "$1" "$SC" || { echo "FAIL: skill: $2" >&2; fail=1; }; }
need '^### Work-day cadence' 'documents the work-day cadence'
need '^work_hours:' 'settings block documents work_hours'
need 'super-conductor-prefs\.mjs interval' 'names the cadence resolver'
need '^### Message wake' 'documents the message wake'
need 'SUPER-CONDUCTOR MESSAGE' 'documents the MESSAGE wake line'
need 'hq channels list --json --active-since' 'sweeps channels with activity, not a fixed few'
need 'hq_channels_swept_at' 'save file keeps the active-since bound'
need '^### Only open threads reach the owner' 'documents the open-thread rule'
need 'owner_reply_check' 'ties the rule to the owner preference'

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor-work-hours: ok"
