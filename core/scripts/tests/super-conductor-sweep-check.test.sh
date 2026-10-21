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

# 1. Targets expand per workspace and account, sessions first.
got="$(node "$SC" targets | tr '\n' ' ')"
want="sessions hq_dms hq_channels slack:ws-one slack:ws-two email:a@example.com email:b@example.com x "
check "targets expand (got: $got)" "$([[ "$got" == "$want" ]]; echo $?)"

since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sleep 1

# 2. The live-run bug: only sessions and hq_dms read. Must fail and name the rest.
rec --target sessions --cursor m1
rec --target hq_dms --cursor 2026-10-18T00:00:00Z
set +e; out="$(node "$SC" verify --state "$state" --since "$since")"; rc=$?; set -e
check "partial sweep exits 1 (got $rc)" "$([[ $rc -eq 1 ]]; echo $?)"
for t in hq_channels slack:ws-one slack:ws-two email:a@example.com email:b@example.com x; do
  grep -q "NOT SWEPT:.*$t" <<<"$out"; check "partial sweep names $t" $?
done
grep -q 'Read: sessions, hq_dms' <<<"$out"; check "status line names channels read" $?
grep -qi 'nothing new' <<<"$out" && check "status line never says nothing new" 1

# 3. Unavailable is refused until every fallback path was tried.
set +e; rec --target email:a@example.com --unavailable "superhuman needs re-auth" --tried mail_mcp 2>/dev/null; rc=$?; set -e
check "unavailable with untried fallbacks is refused (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"

# 4. Full sweep, one account honestly unavailable: passes and names the skip.
rec --target hq_channels --cursor c1
rec --target slack:ws-one --cursor 1.0
rec --target slack:ws-two --cursor 2.0
rec --target email:a@example.com --unavailable "superhuman needs re-auth" --tried hq_integration,mail_mcp,gmail_connector
rec --target email:b@example.com --cursor t9
rec --target x --cursor x1
out="$(node "$SC" verify --state "$state" --since "$since")"; check "full sweep passes" $?
grep -q 'Skipped: email:a@example.com (superhuman needs re-auth)' <<<"$out"; check "status line names skipped account" $?

# 5. An unavailable mark expires after an hour: recheck is due.
later="$(node -e 'console.log(new Date(Date.now()+61*60*1000).toISOString())')"
set +e; out="$(node "$SC" verify --state "$state" --since "$since" --now "$later")"; rc=$?; set -e
check "stale unavailable fails after an hour (rc $rc)" "$([[ $rc -eq 1 ]]; echo $?)"
grep -q 'email:a@example.com (unavailable recheck due' <<<"$out"; check "names recheck due" $?

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
  for t in sessions hq_dms hq_channels slack:ws-one slack:ws-two email:a@example.com email:b@example.com x; do
    node "$SC" record --state "$state" --target "\$t" --cursor c
  done
  exit 3
fi
echo '{"error":"link_not_found"}'; exit 1
EOF
out="$(HQ_BIN="$tmp/hq" bash "$HB" --interval 1 --link cl-t --state "$state")"
check "heartbeat passes a full sweep (out: $out)" "$(! grep -q SWEEP-INCOMPLETE <<<"$out"; echo $?)"

[[ "$fail" -eq 0 ]] && echo "super-conductor-sweep-check: all checks passed" || exit 1
