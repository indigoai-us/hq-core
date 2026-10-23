#!/usr/bin/env bash
# super-conductor-state.mjs: the save file is patched one key at a time.
#   - set creates parents, replaces values, keeps every other key;
#   - push appends to an array, creating it;
#   - del removes a key and refuses a missing one;
#   - a non-JSON value is stored as a string; JSON is stored as JSON;
#   - prototype keys are refused; writes are atomic and bump updated_at;
#   - the skill tells the conductor to use it instead of rewriting the file.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ST="$ROOT/core/scripts/super-conductor-state.mjs"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi; }
F="$tmp/state.json"

printf '{"children":{"a":"local_1"},"open_decisions":[{"id":"d1"}],"sweep":{"hq_dms":{"status":"swept"}}}\n' >"$F"
node "$ST" set "$F" heartbeat.monitor_id mon_abc >/dev/null
out="$(node "$ST" get "$F" heartbeat.monitor_id)"
check "set creates parents and stores a bare string (got: $out)" "$([[ "$out" == '"mon_abc"' ]]; echo $?)"
node "$ST" set "$F" heartbeat.interval 300 >/dev/null
out="$(node "$ST" get "$F" heartbeat.interval)"
check "a JSON value is stored as JSON (got: $out)" "$([[ "$out" == '300' ]]; echo $?)"
out="$(node "$ST" get "$F" sweep.hq_dms.status)"
check "other keys survive a set (got: $out)" "$([[ "$out" == '"swept"' ]]; echo $?)"
node "$ST" push "$F" open_decisions '{"id":"d2","source":"session:local_2"}' >/dev/null
out="$(node "$ST" get "$F" open_decisions)"
check "push appends to an existing array (got: $out)" "$(grep -q '"d1".*"d2"' <<<"$out"; echo $?)"
node "$ST" push "$F" resolved '"d0"' >/dev/null
out="$(node "$ST" get "$F" resolved)"
check "push creates a missing array (got: $out)" "$([[ "$out" == '["d0"]' ]]; echo $?)"
node "$ST" del "$F" sweep.hq_dms >/dev/null
out="$(node "$ST" get "$F" sweep)"
check "del removes a key (got: $out)" "$([[ "$out" == '{}' ]]; echo $?)"
node "$ST" del "$F" sweep.nothing >/dev/null 2>&1; rc=$?
check "del refuses a missing key (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$ST" set "$F" __proto__.x 1 >/dev/null 2>&1; rc=$?
check "a prototype key is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
out="$(node "$ST" get "$F" updated_at)"
check "a write bumps updated_at (got: $out)" "$(grep -q '^"20' <<<"$out"; echo $?)"
check "no temp file is left behind" "$([[ -z "$(ls "$tmp" | grep tmp)" ]]; echo $?)"
node "$ST" set "$tmp/new/state.json" a.b 1 >/dev/null
out="$(node "$ST" get "$tmp/new/state.json" a)"
check "a missing file is created with its folder (got: $out)" "$([[ "$out" == '{"b":1}' ]]; echo $?)"
# Concurrent writers (the watcher's record, the conductor's set) lose nothing.
SW="$ROOT/core/scripts/super-conductor-sweep-check.mjs"
C="$tmp/concurrent.json"; printf '{}\n' >"$C"
for i in 1 2 3 4 5; do node "$ST" set "$C" "k$i" "$i" >/dev/null & node "$SW" record --state "$C" --target "t$i" --cursor "c$i" >/dev/null & done; wait
out="$(node "$ST" get "$C")"
n="$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write(String([1,2,3,4,5].filter(i=>s["k"+i]===i && s.sweep && s.sweep["t"+i]).length))' "$C")"
check "ten concurrent writers (set and record) all land (got $n of 5 pairs: $out)" "$([[ "$n" -eq 5 ]]; echo $?)"
check "no lock directory is left behind" "$([[ ! -e "$C.lock" ]]; echo $?)"
# A lock left by a killed holder is taken over, and a usage error inside the
# locked section releases it.
mkdir "$C.lock"; touch -t 202001010000 "$C.lock"
node "$ST" set "$C" after_stale 1 >/dev/null; rc=$?
check "a stale lock from a dead holder is taken over (rc $rc)" "$([[ $rc -eq 0 && ! -e "$C.lock" ]]; echo $?)"
node "$ST" del "$C" nothing.here >/dev/null 2>&1
check "a usage error inside the lock releases it" "$([[ ! -e "$C.lock" ]]; echo $?)"

SC="$ROOT/.claude/skills/super-conductor/SKILL.md"
grep -q 'super-conductor-state.mjs set' "$SC"; check "the skill patches the save file with super-conductor-state.mjs" $?
grep -q 'super-conductor-state.mjs' "$ROOT/.claude/skills/super-conductor/SKILL.md" && grep -q 'node core/scripts/super-conductor-state.mjs' <(sed -n 1,6p "$SC"); check "the skill allows the state command" $?
grep -q 'open-asks.mjs queued' "$SC"; check "after a compact the skill re-asks from open-asks.mjs queued" $?
OV="$ROOT/.claude/skills/overnight/SKILL.md"
check "overnight no longer uses hq dm inbox --unread" "$(! grep -q -- 'inbox --unread' "$OV"; echo $?)"
grep -q -- '--asks workspace/reports/conduct/<link>-asks.json' "$OV"; check "the overnight restart keeps the open-ask wake" $?
grep -q -- '--message-watch workspace/reports/conduct/<link>-message-watch.json' "$OV"; check "the overnight restart keeps the message wake" $?
grep -q -- '--company "$(bash core/scripts/hq-session.sh get company_slugs)"' "$OV"; check "the overnight restart keeps the company set" $?

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor-state: ok"
