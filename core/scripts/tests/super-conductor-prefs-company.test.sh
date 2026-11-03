#!/usr/bin/env bash
# Pins the per-company super-conductor settings overlay
# (super-conductor-prefs.mjs --company <slug>):
#   - `get --company X` merges personal/settings/super-conductor.X.yaml over the
#     base file (maps one level deep, lists and scalars replace), and reports
#     _company and _overlay;
#   - `add` and `set` with --company write the overlay and leave the base file
#     byte-for-byte;
#   - without --company the overlay is ignored;
#   - interval, channels, critical and exclude honor the overlay;
#   - the heartbeat passes --company to the prefs helper when its --company
#     set is one company, and not for a multi-company set;
#   - a bad slug is refused.
set -uo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
PREFS="$ROOT/core/scripts/super-conductor-prefs.mjs"
HB="$ROOT/core/scripts/super-conductor-heartbeat.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi; }
prefs() { SC_PREFS_FILE="$tmp/p.yaml" node "$PREFS" "$@"; }

cat >"$tmp/p.yaml" <<'EOF'
# base prefs (comment kept)
channels:
  - hq_dms
  - github
watch_interval:
  present: 1   # base cadence
  away: 1500
work_hours: {timezone: UTC, days: sun-sat, start: "00:00", end: "24:00"}
team:
  - Ada
critical_channels:
  - "hq_dm:team"
hq_channels_exclude:
  - chn_base
standing_rule: "base rule"
EOF
cp "$tmp/p.yaml" "$tmp/orig.yaml"

# 1. No overlay yet: --company resolves like the base, names the overlay path.
out="$(prefs --company co-b get)"
node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(j._company==="co-b"&&/p\.co-b\.yaml$/.test(j._overlay)&&/p\.yaml$/.test(j._file)&&j.watch_interval.present===1?0:1)' <<<"$out"
check "get --company without an overlay file equals the base and names the overlay" $?

# 2. set/add with --company create and write only the overlay.
prefs --company co-b set watch_interval.present 2 >/dev/null; check "set --company writes" $?
prefs --company co-b add team Bob >/dev/null; check "add --company writes" $?
prefs --company co-b set standing_rule "co-b rule" >/dev/null; check "set --company scalar writes" $?
prefs --company co-b add hq_channels_exclude chn_b >/dev/null; check "add --company list writes" $?
[[ -f "$tmp/p.co-b.yaml" ]]; check "overlay file is created next to the base" $?
cmp -s "$tmp/p.yaml" "$tmp/orig.yaml"; check "base file is byte-for-byte unchanged" $?
grep -q '^  present: 2' "$tmp/p.co-b.yaml"; check "overlay holds the company value" $?

# 3. get --company merges: map one level deep, list replaces, scalar replaces.
out="$(prefs --company co-b get)"
node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(j.watch_interval.present===2&&j.watch_interval.away===1500&&j.team.join()==="Ada,Bob"&&j.standing_rule==="co-b rule"&&j.channels.join()==="hq_dms,github"&&j.hq_channels_exclude.join()==="chn_base,chn_b"?0:1)' <<<"$out"
check "overlay merges maps, seeds added lists from the base, replaces scalars, keeps untouched keys" $?
printf 'team:\n  - Zed\n' >"$tmp/p.co-c.yaml"
out="$(prefs --company co-c get)"
node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(j.team.join()==="Zed"&&j.watch_interval.present===1?0:1)' <<<"$out"
check "a hand-written overlay list replaces the base list" $?
out="$(prefs get)"
node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(j.watch_interval.present===1&&j.team.join()==="Ada"&&j.standing_rule==="base rule"&&j._company===undefined?0:1)' <<<"$out"
check "without --company the overlay is ignored" $?
out="$(prefs --company co-a get)"
node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(j.watch_interval.present===1&&j.team.join()==="Ada"?0:1)' <<<"$out"
check "another company without an overlay sees the base" $?

# 4. Derived commands honor the overlay.
[[ "$(prefs --company co-b interval)" == "2 present" ]]; check "interval uses the overlay cadence" $?
[[ "$(prefs interval)" == "1 present" ]]; check "interval without --company uses the base" $?
[[ "$(prefs --company co-b critical)" == $'hq_dm:team\tAda,Bob\t60' ]]; check "critical uses the overlay team" $?
[[ "$(prefs --company co-b exclude)" == "chn_base,chn_b" ]]; check "exclude uses the overlay list" $?
prefs --company co-b add channels email >/dev/null
[[ "$(prefs --company co-b channels)" == "sessions,hq_dms,github,email" ]]; check "channels: the first add to an overlay list starts from the base list" $?
grep -q '^  - hq_dms' "$tmp/p.co-b.yaml"; check "the seeded base items are written into the overlay" $?
prefs --company co-b add channels x >/dev/null
[[ "$(prefs --company co-b channels)" == "sessions,hq_dms,github,email,x" ]]; check "a later add extends the overlay list" $?
[[ "$(prefs channels)" == "sessions,hq_dms,github" ]]; check "channels without --company unchanged" $?
prefs --file "$tmp/p.yaml" --company co-b interval >/dev/null; check "--file and --company compose" $?

# 5. Heartbeat: one company -> overlay cadence and channels; two -> base.
# (--once still waits one interval before its line, so cadences are 1s and 2s.)
export SC_HEARTBEAT_MIN_INTERVAL=1 SC_PREFS_FILE="$tmp/p.yaml"
out="$(bash "$HB" --interval auto --asks "$tmp/asks.json" --company co-b --once 2>/dev/null)"
grep -q 'channels: sessions,hq_dms,github,email,x (from settings) | cadence: present 2s' <<<"$out"; check "heartbeat with one --company reads that company's overlay (got: $out)" $?
out="$(bash "$HB" --interval auto --asks "$tmp/asks.json" --company co-a,co-b --once 2>/dev/null)"
grep -q 'channels: sessions,hq_dms,github (from settings) | cadence: present 1s' <<<"$out"; check "heartbeat with two companies reads the base file (got: $out)" $?
unset SC_PREFS_FILE

# 6. A bad slug is refused.
prefs --company 'Bad Slug' get >/dev/null 2>&1; [[ $? -eq 2 ]]; check "an invalid --company slug exits 2" $?

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor prefs company overlay: ok"
