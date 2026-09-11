#!/usr/bin/env bash
# hq-core: public
# hq-detach.sh — portable session detach (setsid or node child.detached).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DETACH="$ROOT/core/scripts/hq-detach.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

kill "$pid" 2>/dev/null || true
echo "hq-detach: all passed"
