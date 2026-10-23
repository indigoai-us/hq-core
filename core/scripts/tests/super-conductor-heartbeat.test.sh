#!/usr/bin/env bash
# Behavior test for core/scripts/super-conductor-heartbeat.sh, the persistent
# wake source that keeps /super-conductor sweeping without owner nudges.
# Uses a fake `hq` so no link or network is needed.
set -euo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
HB="$ROOT/core/scripts/super-conductor-heartbeat.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # description condition-exit-code
  if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi
}

export SC_HEARTBEAT_MIN_INTERVAL=1 SC_HEARTBEAT_ERROR_BACKOFF=0

# Fake hq: behavior per call number, read from $tmp/script (one rc per line).
cat >"$tmp/hq" <<'EOF'
#!/usr/bin/env bash
dir="$(dirname "$0")"
n=$(( $(cat "$dir/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$dir/count"
echo "$*" >>"$dir/calls"
rc="$(sed -n "${n}p" "$dir/script")"
[[ -z "$rc" ]] && rc="$(tail -n1 "$dir/script")"
case "$rc" in
  0) echo '{"pending":true}'; exit 0 ;;
  3) echo '{"pending":false,"timeout":true}'; exit 3 ;;
  gone) echo '{"error":"link_not_found","message":"No such link: cl-test"}'; exit 1 ;;
  net) echo 'error: Connection closed'; exit 1 ;;
  *) echo 'error: boom'; exit "$rc" ;;
esac
EOF
chmod +x "$tmp/hq"
export HQ_BIN="$tmp/hq"
reset() { rm -f "$tmp/count" "$tmp/calls"; printf '%s\n' "$@" >"$tmp/script"; }

# 1. Bad interval is rejected.
set +e; bash "$HB" --interval soon >/dev/null 2>&1; rc=$?; set -e
check "non-numeric interval exits 2 (got $rc)" "$([[ $rc -eq 2 ]]; echo $?)"

# 2. No link: a plain timer TICK carrying channels and the save-file hint.
out="$(bash "$HB" --interval 1 --channels hq_dms,slack --state /x/state.json --once)"
grep -q '^SUPER-CONDUCTOR TICK ' <<<"$out"; check "timer mode prints TICK" $?
grep -q 'channels: hq_dms,slack' <<<"$out"; check "TICK names the channels" $?
grep -q 'Read /x/state.json' <<<"$out"; check "TICK points at the save file" $?

# 3. Link wait times out (exit 3) -> TICK, and the wait uses the interval.
reset 3
out="$(bash "$HB" --interval 1 --link cl-test --once)"
grep -q '^SUPER-CONDUCTOR TICK ' <<<"$out"; check "wait timeout prints TICK" $?
grep -q -- 'lanes link wait --link cl-test --timeout 1' "$tmp/calls"; check "wait is bounded by the interval" $?

# 4. Report -> REPORT, then a timer TICK (no hq call), then link closed -> exit 0.
reset 0 gone
set +e; out="$(bash "$HB" --interval 1 --link cl-test)"; rc=$?; set -e
kinds="$(awk '{print $2}' <<<"$out" | tr '\n' ' ')"
check "report sequence is REPORT TICK LINK-CLOSED (got: $kinds)" "$([[ "$kinds" == "REPORT TICK LINK-CLOSED " ]]; echo $?)"
check "link closed exits 0 (got $rc)" "$([[ $rc -eq 0 ]]; echo $?)"
check "timer after REPORT does not re-wait (calls: $(wc -l <"$tmp/calls"))" "$([[ $(wc -l <"$tmp/calls") -eq 2 ]]; echo $?)"

# 5. Repeated waiter errors -> WAITER-ERROR lines, then STOPPED and exit 1.
reset 7
set +e; out="$(SC_HEARTBEAT_MAX_ERRORS=2 bash "$HB" --interval 1 --link cl-test)"; rc=$?; set -e
check "two WAITER-ERROR lines" "$([[ $(grep -c '^SUPER-CONDUCTOR WAITER-ERROR ' <<<"$out") -eq 2 ]]; echo $?)"
grep -q '^SUPER-CONDUCTOR STOPPED ' <<<"$out"; check "gives up with STOPPED" $?
check "gives up with exit 1 (got $rc)" "$([[ $rc -eq 1 ]]; echo $?)"

# 6. A network error that mentions "closed" is not mistaken for a closed link.
reset net
set +e; out="$(SC_HEARTBEAT_MAX_ERRORS=1 bash "$HB" --interval 1 --link cl-test)"; rc=$?; set -e
check "connection closed is a waiter error, not LINK-CLOSED (rc $rc)" "$([[ $rc -eq 1 ]] && ! grep -q LINK-CLOSED <<<"$out"; echo $?)"

# 7. Interval above 3600 is clamped (visible in the wait timeout).
reset 3
bash "$HB" --interval 99999 --link cl-test --once >/dev/null
grep -q -- '--timeout 3600' "$tmp/calls"; check "interval clamps to 3600" $?

# 8. Argument checks for the watcher flags.
for args in "--interval 1 --message-watch /x/w.json" "--interval 1 --message-watch --company co-a" "--interval 1 --asks /x/a.json" "--interval 1 --asks --company co-a" "--interval 1 --bogus"; do
  set +e; bash "$HB" $args --once >/dev/null 2>&1; rc=$?; set -e
  check "bad arguments exit 2: $args (got $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
done

# 8b. --asks passes --conductor and --exclude (each repeatable) through to the
# open-asks watcher, which stops with the heartbeat.
bash "$HB" --interval 60 --asks "$tmp/asks.json" --company co-a --conductor local_one --conductor local_two --exclude sid-self >"$tmp/hb-asks.out" 2>&1 &
hb_pid=$!
args=""
for _ in $(seq 1 50); do
  wp="$(pgrep -f "open-asks.mjs watch .*$tmp/asks.json" | head -n1 || true)"
  [[ -n "$wp" ]] && { args="$(ps -o args= -p "$wp")"; break; }
  sleep 0.1
done
kill "$hb_pid" 2>/dev/null || true; wait "$hb_pid" 2>/dev/null || true
grep -q -- '--conductor local_one' <<<"$args" && grep -q -- '--conductor local_two' <<<"$args"; check "the heartbeat passes every --conductor to the ask watcher (got: $args)" $?
grep -q -- '--exclude sid-self' <<<"$args"; check "the heartbeat passes --exclude to the ask watcher (got: $args)" $?
gone=1
for _ in $(seq 1 30); do pgrep -f "open-asks.mjs watch .*$tmp/asks.json" >/dev/null || { gone=0; break; }; sleep 0.1; done
check "the ask watcher stops with the heartbeat" "$gone"

# 9. Coverage map (review on #1583): the heartbeat grew its watcher flags in
# one PR; each flag in its usage line must be exercised by some suite.
usage_line="$(grep -m1 '^  echo "usage:' "$HB")"
for flag in $(grep -o -E -- '--[a-z-]+' <<<"$usage_line" | sort -u); do
  hits="$(grep -l -E -- "(HB|super-conductor-heartbeat\.sh).*${flag}([^a-z-]|$)" "$ROOT"/core/scripts/tests/super-conductor-*.test.sh 2>/dev/null | wc -l | tr -d ' ' || true)"
  check "heartbeat flag $flag is exercised by a test (suites: $hits)" "$([[ "$hits" -gt 0 ]]; echo $?)"
done

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor heartbeat: ok"
