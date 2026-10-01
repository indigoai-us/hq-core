#!/usr/bin/env bash
# hq-core: public
# hq-detach.sh — portable session detach (setsid or node child.detached).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DETACH="$ROOT/core/scripts/hq-detach.sh"
TMP="$(mktemp -d)"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -z "$p" ] || kill -KILL "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

chmod +x "$DETACH"

SIDFILE="$TMP/sid.txt"
# Force the node path even if setsid exists, so Darwin and Linux share coverage.
HQ_DETACH_FORCE_NODE=1 \
  bash "$DETACH" --pidfile "$TMP/lane.pid" --logfile "$TMP/lane.log" -- \
  node -e "const fs=require('fs'); const {execSync}=require('child_process'); const pid=process.pid; let sid=String(pid); try { sid=String(execSync('ps -o sid= -p '+pid,{encoding:'utf8'})).trim()||sid; } catch (e) {} fs.writeFileSync(process.argv[1], pid+' '+sid+'\n'); setTimeout(()=>{}, 2000);" "$SIDFILE"

[ -s "$TMP/lane.pid" ] || fail "pidfile missing"
pid="$(tr -d '[:space:]' < "$TMP/lane.pid")"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -s "$SIDFILE" ] && break
  sleep 0.1
done
[ -s "$SIDFILE" ] || fail "child did not write sid.txt (log=$(cat "$TMP/lane.log" 2>/dev/null))"
child_pid="$(awk '{print $1}' "$SIDFILE")"
child_sid="$(awk '{print $2}' "$SIDFILE")"
[ -n "$child_pid" ] && [ -n "$child_sid" ] || fail "sid.txt malformed: $(cat "$SIDFILE")"
[ "$child_pid" = "$child_sid" ] || fail "expected sid==pid (session leader), got pid=$child_pid sid=$child_sid"
pass "node detach: sid equals pid ($child_pid)"

# When requested by conduct, capture the live Claude owner before detaching.
cat > "$TMP/claude" <<'OWNER'
#!/usr/bin/env bash
bash "$DETACH" --pidfile "$OWNED_LANE_PIDFILE" --owner-pidfile "$OWNER_PIDFILE" \
  --logfile "$TMP_OWNER_LOG" -- sleep 20
sleep 4
OWNER
chmod +x "$TMP/claude"
DETACH="$DETACH" OWNED_LANE_PIDFILE="$TMP/owned-lane.pid" \
  OWNER_PIDFILE="$TMP/owner.pid" TMP_OWNER_LOG="$TMP/owned-lane.log" \
  "$TMP/claude" &
owner_pid=$!
PIDS+=("$owner_pid")
for _ in $(seq 1 30); do [ -s "$TMP/owner.pid" ] && break; sleep 0.1; done
[ -s "$TMP/owner.pid" ] || fail "owner pidfile missing or detached launch could not find the Claude ancestor"
recorded_owner="$(sed -n '1p' "$TMP/owner.pid")"
recorded_start="$(sed -n '2p' "$TMP/owner.pid")"
[ "$recorded_owner" = "$owner_pid" ] || fail "owner pidfile recorded $recorded_owner, expected live owner $owner_pid"
[ -n "$recorded_start" ] || fail "owner process start identity missing"
[ -s "$TMP/owned-lane.pid" ] || fail "owner lane pidfile missing"
owned_lane_pid="$(cat "$TMP/owned-lane.pid")"
PIDS+=("$owned_lane_pid")
pass "detached launch records its owning Claude pid and start identity"
kill "$owned_lane_pid" "$owner_pid" 2>/dev/null || true

kill "$pid" 2>/dev/null || true
echo "hq-detach: all passed"
