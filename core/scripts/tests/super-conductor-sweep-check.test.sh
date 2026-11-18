#!/usr/bin/env bash
# Regression test: a /super-conductor wakeup that skips a selected channel,
# workspace, or account is flagged; a full sweep passes. Covers
# core/scripts/super-conductor-sweep-check.mjs and its heartbeat wiring.
set -euo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
SC="$ROOT/core/scripts/super-conductor-sweep-check.mjs"
HB="$ROOT/core/scripts/super-conductor-heartbeat.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi; }

cat >"$tmp/prefs.yaml" <<'EOF'
channels:
  - hq_dms
  - hq_channels
  - slack
  - email
  - x
slack_workspaces:
  - ws-one
  - ws-two
email_accounts:
  - a@example.com
  - b@example.com
EOF
export SC_PREFS_FILE="$tmp/prefs.yaml"
state="$tmp/state.json"
rec() { node "$SC" record --state "$state" "$@"; }

# 1. Targets expand per workspace and account, sessions first, then
# subagent_runs (each adopted conduct session's runs.json), which is always
# swept: default-mode subagents never show in `hq runners link list`.
got="$(node "$SC" targets | tr '\n' ' ')"
want="sessions subagent_runs senior_lanes hq_dms hq_channels slack:ws-one slack:ws-two email:a@example.com email:b@example.com x "
check "targets expand (got: $got)" "$([[ "$got" == "$want" ]]; echo $?)"

since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sleep 1

# 2. The live-run bug: only sessions and hq_dms read. Must fail and name the rest.
rec --target sessions --cursor m1
rec --target hq_dms --cursor 2026-10-18T00:00:00Z
set +e; out="$(node "$SC" verify --state "$state" --since "$since")"; rc=$?; set -e
check "partial sweep exits 1 (got $rc)" "$([[ $rc -eq 1 ]]; echo $?)"
for t in subagent_runs senior_lanes hq_channels slack:ws-one slack:ws-two email:a@example.com email:b@example.com x; do
  grep -q "NOT SWEPT:.*$t" <<<"$out"; check "partial sweep names $t" $?
done
grep -q 'Read: sessions, hq_dms' <<<"$out"; check "status line names channels read" $?
grep -qi 'nothing new' <<<"$out" && check "status line never says nothing new" 1

# 3. Unavailable is refused until every fallback path was tried.
set +e; rec --target email:a@example.com --unavailable "superhuman needs re-auth" --tried mail_mcp 2>/dev/null; rc=$?; set -e
check "unavailable with untried fallbacks is refused (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"

# 3b. subagent_runs is a channel of its own: --channels never drops it, a
# channel list that names it does not repeat it, and it is marked unavailable
# only after the runs.json read was tried.
got="$(node "$SC" targets --channels hq_dms | tr '\n' ' ')"
check "subagent_runs is swept whatever the channel list (got: $got)" "$([[ "$got" == "sessions subagent_runs senior_lanes hq_dms " ]]; echo $?)"
got="$(node "$SC" targets --channels subagent_runs,sessions,hq_dms | tr '\n' ' ')"
check "a listed subagent_runs is not repeated (got: $got)" "$([[ "$got" == "sessions subagent_runs senior_lanes hq_dms " ]]; echo $?)"
set +e; rec --target subagent_runs --unavailable "no runs file" --tried ccd_list_sessions 2>/dev/null; rc=$?; set -e
check "subagent_runs unavailable without the runs.json read is refused (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"

# 3c. senior_lanes (the lanes naming this session as senior, and their
# pending questions) is swept in default mode too: the Executive opens its
# lanes under the conductor whatever conduct.runner says, so a wakeup that
# skips the read is flagged, --channels never drops it, and it is marked
# unavailable only after both the lane list and the questions read were tried.
check "the partial sweep names senior_lanes" "$(grep -q 'NOT SWEPT:.*senior_lanes' <<<"$out"; echo $?)"
got="$(node "$SC" targets --channels hq_dms | tr '\n' ' ')"
check "senior_lanes is swept whatever the channel list (got: $got)" "$([[ "$got" == *" senior_lanes "* ]]; echo $?)"
set +e; rec --target senior_lanes --unavailable "lanes store unreadable" --tried hq_lanes_list_senior 2>/dev/null; rc=$?; set -e
check "senior_lanes unavailable without the questions read is refused (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"

# 4. Full sweep, one account honestly unavailable: passes and names the skip.
rec --target subagent_runs --cursor runs-mtime-1
rec --target senior_lanes --cursor q-none
rec --target hq_channels --cursor c1
rec --target slack:ws-one --cursor 1.0
rec --target slack:ws-two --cursor 2.0
rec --target email:a@example.com --unavailable "superhuman needs re-auth" --tried hq_integration,mail_mcp,gmail_connector
rec --target email:b@example.com --cursor t9
rec --target x --cursor x1
out="$(node "$SC" verify --state "$state" --since "$since")"; check "full sweep passes" $?
grep -q 'Skipped: email:a@example.com (superhuman needs re-auth)' <<<"$out"; check "status line names skipped account" $?
grep -q 'Read: sessions, subagent_runs, senior_lanes, hq_dms' <<<"$out"; check "status line names the runs.json read (got: $out)" $?

# 5. An unavailable mark expires after an hour: recheck is due, but it is not a missed sweep.
later="$(node -e 'console.log(new Date(Date.now()+61*60*1000).toISOString())')"
set +e; out="$(node "$SC" verify --state "$state" --since "$since" --now "$later")"; rc=$?; set -e
check "stale unavailable is not a missed sweep (rc $rc)" "$([[ $rc -eq 0 ]]; echo $?)"
grep -q 'Recheck due (unavailable over an hour): email:a@example.com (superhuman needs re-auth)' <<<"$out"; check "names recheck due (got: $out)" $?
grep -q 'NOT SWEPT' <<<"$out" && check "recheck due is not listed as NOT SWEPT (got: $out)" 1
out="$(node "$SC" due --state "$state" --now "$later")"
grep -q '^email:a@example.com$' <<<"$out"; check "due lists the stale unavailable target again (got: $out)" $?

# 6. Heartbeat wiring: second wake flags a sweep that missed channels.
export SC_HEARTBEAT_MIN_INTERVAL=1
echo '{"sweep":{}}' >"$state"
cat >"$tmp/hq" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$(dirname "$0")/n" 2>/dev/null || echo 0) + 1 )); echo $n >"$(dirname "$0")/n"
if (( n < 3 )); then exit 3; fi
echo '{"error":"link_not_found"}'; exit 1
EOF
chmod +x "$tmp/hq"
out="$(HQ_BIN="$tmp/hq" bash "$HB" --interval 1 --link cl-t --state "$state")"
grep -q '^SUPER-CONDUCTOR SWEEP-INCOMPLETE .*NOT SWEPT:.*slack:ws-two' <<<"$out"; check "heartbeat flags skipped sweep" $?
check "first wake is not flagged" "$([[ $(grep -c SWEEP-INCOMPLETE <<<"$out") -eq 1 ]]; echo $?)"

# 7. Heartbeat wiring: a full sweep between wakes is not flagged.
rm -f "$tmp/n"
cat >"$tmp/hq" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$tmp/n" 2>/dev/null || echo 0) + 1 )); echo \$n >"$tmp/n"
if (( n == 1 )); then exit 3; fi
if (( n == 2 )); then
  for t in sessions subagent_runs senior_lanes hq_dms hq_channels slack:ws-one slack:ws-two email:a@example.com email:b@example.com x; do
    node "$SC" record --state "$state" --target "\$t" --cursor c
  done
  exit 3
fi
echo '{"error":"link_not_found"}'; exit 1
EOF
out="$(HQ_BIN="$tmp/hq" bash "$HB" --interval 1 --link cl-t --state "$state")"
check "heartbeat passes a full sweep (out: $out)" "$(! grep -q SWEEP-INCOMPLETE <<<"$out"; echo $?)"

# 8. Heartbeat wiring: sweep evidence is judged tick to tick. A REPORT wake
# a moment after a tick is never itself judged as a sweep: the missing
# evidence is reported at the next tick, after the REPORT, not before it.
rm -f "$tmp/n"
echo '{"sweep":{}}' >"$state"
cat >"$tmp/hq" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$tmp/n" 2>/dev/null || echo 0) + 1 )); echo \$n >"$tmp/n"
if (( n == 1 )); then exit 3; fi
if (( n == 2 )); then echo '{"pending":true}'; exit 0; fi
echo '{"error":"link_not_found"}'; exit 1
EOF
out="$(HQ_BIN="$tmp/hq" bash "$HB" --interval 1 --link cl-t --state "$state")"
kinds="$(awk '/^SUPER-CONDUCTOR/{print $2}' <<<"$out" | tr '\n' ' ')"
check "a REPORT right after a tick is not judged; the next tick is (got: $kinds)" "$([[ "$kinds" == "TICK REPORT SWEEP-INCOMPLETE TICK LINK-CLOSED " ]]; echo $?)"

# 8. Heartbeat wiring: sweep evidence is judged tick to tick. A REPORT wake
# a moment after a tick is never itself judged as a sweep: the missing
# evidence is reported at the next tick, after the REPORT, not before it.
rm -f "$tmp/n"
echo '{"sweep":{}}' >"$state"
cat >"$tmp/hq" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$tmp/n" 2>/dev/null || echo 0) + 1 )); echo \$n >"$tmp/n"
if (( n == 1 )); then exit 3; fi
if (( n == 2 )); then echo '{"pending":true}'; exit 0; fi
echo '{"error":"link_not_found"}'; exit 1
EOF
out="$(HQ_BIN="$tmp/hq" bash "$HB" --interval 1 --link cl-t --state "$state")"
kinds="$(awk '/^SUPER-CONDUCTOR/{print $2}' <<<"$out" | tr '\n' ' ')"
check "a REPORT right after a tick is not judged; the next tick is (got: $kinds)" "$([[ "$kinds" == "TICK REPORT SWEEP-INCOMPLETE TICK LINK-CLOSED " ]]; echo $?)"

# 9. hq_channels sweep: the channel filter drops every channel in
# hq_channels_exclude (slug or id, case-insensitive) and --exclude, so an
# excluded channel is never read or counted as unswept; the rest stay.
SCOPE="$ROOT/core/scripts/lib/super-conductor-scope.mjs"
mkdir -p "$tmp/root/companies"
printf 'companies:\n  co-a:\n    cloud_uid: cmp_co-a\n' >"$tmp/root/companies/manifest.yaml"
echo '[{"channelId":"chn_keep","companyUid":"cmp_co-a","slug":"hq-dev"},{"channelId":"chn_rev","companyUid":"cmp_co-a","slug":"project-core-pr-reviews-6e234042"},{"channelId":"chn_fb","companyUid":"cmp_co-a","slug":"project-hq-feedback-zero-8cfb3210"}]' >"$tmp/rows.json"
ids() { node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); process.stdout.write((Array.isArray(d)?d:d.rows).map(r=>r.channelId).join(","))'; }
got="$(HQ_ROOT="$tmp/root" node "$SCOPE" filter-channels --company co-a <"$tmp/rows.json" | ids)"
check "without an exclude list every in-scope channel stays (got: $got)" "$([[ "$got" == "chn_keep,chn_rev,chn_fb" ]]; echo $?)"
printf 'hq_channels_exclude:\n  - Project-Core-PR-Reviews-6e234042\n  - chn_fb\n' >>"$tmp/prefs.yaml"
got="$(HQ_ROOT="$tmp/root" node "$SCOPE" filter-channels --company co-a <"$tmp/rows.json" | ids)"
check "hq_channels_exclude drops the listed channels by slug or id (got: $got)" "$([[ "$got" == "chn_keep" ]]; echo $?)"
printf '{"rows":%s}' "$(cat "$tmp/rows.json")" >"$tmp/changes.json"
got="$(HQ_ROOT="$tmp/root" node "$SCOPE" filter-channels --company co-a --exclude hq-dev <"$tmp/changes.json" | ids)"
check "--exclude drops a channel from a changes object too (got: $got)" "$([[ "$got" == "" ]]; echo $?)"

# 10. Per-company overlay: a conductor bound to one company sweeps that
# company's accounts. The save file's `company` key (or --company) selects
# prefs.<slug>.yaml; a multi-company set and no company read the base file.
cat >"$tmp/co.yaml" <<'EOF'
channels:
  - hq_dms
  - email
email_accounts:
  - me@example.com
  - work@example.com
channel_cadence:
  constant: [sessions, hq_dms, email]
EOF
printf 'email_accounts: only@example.com\n' >"$tmp/co.co-v.yaml"
export SC_PREFS_FILE="$tmp/co.yaml"
cost="$tmp/co-state.json"
echo '{"company":"co-v"}' >"$cost"
got="$(node "$SC" targets --state "$cost" | tr '\n' ' ')"
check "targets read the save file's company overlay (got: $got)" "$([[ "$got" == "sessions subagent_runs senior_lanes hq_dms email:only@example.com " ]]; echo $?)"
got="$(node "$SC" targets | tr '\n' ' ')"
check "targets without a company read the base (got: $got)" "$([[ "$got" == "sessions subagent_runs senior_lanes hq_dms email:me@example.com email:work@example.com " ]]; echo $?)"
got="$(node "$SC" targets --company co-v | tr '\n' ' ')"
check "targets --company reads the overlay (got: $got)" "$([[ "$got" == "sessions subagent_runs senior_lanes hq_dms email:only@example.com " ]]; echo $?)"
got="$(node "$SC" targets --state "$cost" --company co-v,co-w | tr '\n' ' ')"
check "a multi-company --company reads the base (got: $got)" "$([[ "$got" == "sessions subagent_runs senior_lanes hq_dms email:me@example.com email:work@example.com " ]]; echo $?)"
got="$(node "$SC" due --state "$cost" | tr '\n' ' ')"
check "due honors the overlay (got: $got)" "$([[ "$got" == "sessions subagent_runs senior_lanes hq_dms email:only@example.com " ]]; echo $?)"
csince="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; sleep 1
for t in sessions subagent_runs senior_lanes hq_dms email:only@example.com; do node "$SC" record --state "$cost" --target "$t" --cursor c; done
set +e; out="$(node "$SC" verify --state "$cost" --since "$csince")"; rc=$?; set -e
check "verify passes when the overlay's accounts were swept (rc $rc: $out)" "$([[ $rc -eq 0 ]]; echo $?)"
grep -q 'me@example.com\|work@example.com' <<<"$out" && check "verify never names base-only accounts for the company (got: $out)" 1
out="$(node "$SC" status-line --state "$cost" --since "$csince")"
grep -q 'Read: sessions, subagent_runs, senior_lanes, hq_dms, email:only@example.com' <<<"$out"; check "status-line honors the overlay (got: $out)" $?
set +e; node "$SC" verify --state "$cost" --since "$csince" --company '' >/dev/null; rc=$?; set -e
check "--company '' forces the base file, whose accounts were not swept (rc $rc)" "$([[ $rc -eq 1 ]]; echo $?)"
echo '{"company":"Bad Slug"}' >"$tmp/co-bad.json"
got="$(node "$SC" targets --state "$tmp/co-bad.json" | tr '\n' ' ')"
check "a company the prefs helper refuses reads the base, not a one-channel default (got: $got)" "$([[ "$got" == "sessions subagent_runs senior_lanes hq_dms email:me@example.com email:work@example.com " ]]; echo $?)"
# A scalar list value (written by `set`) is one target, not one per character.
printf 'email_accounts: a@example.com, b@example.com\n' >"$tmp/co.co-s.yaml"
got="$(node "$SC" targets --company co-s | tr '\n' ' ')"
check "a comma-separated scalar list expands per account (got: $got)" "$([[ "$got" == "sessions subagent_runs senior_lanes hq_dms email:a@example.com email:b@example.com " ]]; echo $?)"
# Heartbeat: one --company is passed to verify, so the overlay is judged even
# when the save file has no company key. Nothing swept: the second wake flags
# the overlay's account and never the base-only ones.
mkdir -p "$tmp/cohb"
cat >"$tmp/cohb/hq" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$(dirname "$0")/n" 2>/dev/null || echo 0) + 1 )); echo $n >"$(dirname "$0")/n"
if (( n < 3 )); then exit 3; fi
echo '{"error":"link_not_found"}'; exit 1
EOF
chmod +x "$tmp/cohb/hq"
echo '{"sweep":{}}' >"$tmp/cohb/state.json"
out="$(SC_HEARTBEAT_MIN_INTERVAL=1 HQ_BIN="$tmp/cohb/hq" bash "$HB" --interval 1 --link cl-t --state "$tmp/cohb/state.json" --company co-v 2>/dev/null)"
grep -q '^SUPER-CONDUCTOR SWEEP-INCOMPLETE .*NOT SWEPT:.*email:only@example.com' <<<"$out"; check "heartbeat --company judges the overlay's account (got: $out)" $?
grep -q 'NOT SWEPT:.*\(me\|work\)@example.com' <<<"$out" && check "heartbeat --company never flags base-only accounts (got: $out)" 1
unset SC_PREFS_FILE

[[ "$fail" -eq 0 ]] && echo "super-conductor-sweep-check: all checks passed" || exit 1
