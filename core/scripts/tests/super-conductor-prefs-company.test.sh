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

# 6. replace: a company can narrow a base list in its overlay; base untouched.
printf 'email_accounts:\n  - me@example.com\n  - work@example.com\n' >>"$tmp/p.yaml"
cp "$tmp/p.yaml" "$tmp/orig2.yaml"
prefs --company co-d replace email_accounts only@example.com >/dev/null; check "replace --company writes" $?
cmp -s "$tmp/p.yaml" "$tmp/orig2.yaml"; check "replace --company leaves the base file unchanged" $?
out="$(prefs --company co-d get)"
node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(JSON.stringify(j.email_accounts)==="[\"only@example.com\"]"?0:1)' <<<"$out"
check "replace --company narrows the list to exactly the given values (got: $out)" $?
printf 'email_accounts: a@example.com\nteam:\n  - Kim\n' >"$tmp/p.co-e.yaml"
prefs --company co-e replace email_accounts x@example.com y@example.com x@example.com >/dev/null; check "replace over a scalar writes" $?
out="$(prefs --company co-e get)"
node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(j.email_accounts.join()==="x@example.com,y@example.com"&&j.team.join()==="Kim"?0:1)' <<<"$out"
check "replace turns a scalar into a deduplicated list and keeps other keys (got: $out)" $?
prefs --company co-e replace team >/dev/null; check "replace with no values writes" $?
out="$(prefs --company co-e get)"
node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(Array.isArray(j.team)&&j.team.length===0&&j.email_accounts.length===2?0:1)' <<<"$out"
check "replace with no values leaves an empty list (got: $out)" $?
prefs --company co-e replace watch_interval 5 >/dev/null 2>&1; [[ $? -eq 3 ]]; check "replace refuses a map key" $?

# 6b. A single-string email_accounts or slack_workspaces in an overlay (what
# `set` writes) resolves to a list; a comma-separated string splits.
printf 'email_accounts: one@example.com\nslack_workspaces: ws-a, ws-b\n' >"$tmp/p.co-f.yaml"
out="$(prefs --company co-f get)"
node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(JSON.stringify(j.email_accounts)==="[\"one@example.com\"]"&&JSON.stringify(j.slack_workspaces)==="[\"ws-a\",\"ws-b\"]"?0:1)' <<<"$out"
check "string email_accounts and slack_workspaces resolve to lists" $?

# 7. A bad slug is refused.
prefs --company 'Bad Slug' get >/dev/null 2>&1; [[ $? -eq 2 ]]; check "an invalid --company slug exits 2" $?

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor prefs company overlay: ok"
