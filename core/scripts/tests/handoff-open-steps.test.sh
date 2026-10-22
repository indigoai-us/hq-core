#!/usr/bin/env bash
# hq-core: public
# Regression tests for next-step ids/closure: handoff-finalize normalization
# and core/scripts/handoff-open-steps.sh (2026-09-07).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"; S="$ROOT/core/scripts/handoff-open-steps.sh"
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$FX/workspace/threads/archive"
mk() { # <thread_id> <company> <steps-json>
  jq -n --arg id "$1" --arg co "$2" --argjson steps "$3" '{thread_id:$id, version:1, type:"handoff", created_at:"2026-09-01T00:00:00Z", updated_at:"2026-09-01T00:00:00Z", conversation_summary:"s", next_steps:$steps, metadata:{title:("T " + $id), tags:[], company:[$co]}}' > "$FX/workspace/threads/$1.json"
}
mk T-20260901-000000-a acme '["legacy string step", {"step":"object step"}]'
sleep 1
mk T-20260902-000000-b beta '[{"id":"T-20260902-000000-b#1","step":"already normalized","status":"open"},{"id":"T-20260902-000000-b#2","step":"done one","status":"done"}]'

echo "[1] list shows open steps with ids, newest thread first, legacy ids synthesized"
out="$(HQ_ROOT="$FX" bash "$S" list)"
grep -q 'T-20260902-000000-b#1  already normalized' <<<"$out" || fail "normalized step missing: $out"
grep -q 'T-20260901-000000-a#1  legacy string step' <<<"$out" || fail "legacy string step missing: $out"
grep -q 'T-20260901-000000-a#2  object step' <<<"$out" || fail "legacy object step missing: $out"
grep -q 'done one' <<<"$out" && fail "closed step must not be listed"
[ "$(head -1 <<<"$out" | grep -c 'T-20260902')" = 1 ] || fail "newest first: $out"

echo "[2] --company filters; --json is machine-readable"
out="$(HQ_ROOT="$FX" bash "$S" list --company acme --json)"
[ "$(jq 'length' <<<"$out")" = 2 ] || fail "company filter: $out"

echo "[3] close writes status/closed_at into the thread and removes it from the list"
HQ_ROOT="$FX" HQ_SESSION_ID=sess-x bash "$S" close T-20260901-000000-a#1 --note "shipped in PR 1" >/dev/null || fail "close rc"
f="$FX/workspace/threads/T-20260901-000000-a.json"
[ "$(jq -r '.next_steps[0].status' "$f")" = done ] && [ "$(jq -r '.next_steps[0].closed_by' "$f")" = sess-x ] && [ "$(jq -r '.next_steps[0].note' "$f")" = "shipped in PR 1" ] || fail "close fields: $(cat "$f")"
[ "$(jq -r '.next_steps[0].id' "$f")" = "T-20260901-000000-a#1" ] || fail "legacy id must be written on close"
[ "$(jq -r '.next_steps[1].status' "$f")" = open ] || fail "sibling untouched"
[ "$(jq -r '.conversation_summary' "$f")" = s ] || fail "thread body untouched"
HQ_ROOT="$FX" bash "$S" list | grep -q 'legacy string step' && fail "closed step still listed"

echo "[4] close --as dropped, reopen, unknown step"
HQ_ROOT="$FX" bash "$S" close T-20260901-000000-a#2 --as dropped >/dev/null || fail "drop rc"
[ "$(jq -r '.next_steps[1].status' "$f")" = dropped ] || fail "dropped"
HQ_ROOT="$FX" bash "$S" reopen T-20260901-000000-a#2 >/dev/null || fail "reopen rc"
[ "$(jq -r '.next_steps[1].status' "$f")" = open ] || fail "reopen"
rc=0; HQ_ROOT="$FX" bash "$S" close T-20260901-000000-a#9 >/dev/null 2>&1 || rc=$?; [ "$rc" = 3 ] || fail "unknown step rc $rc"

echo "[4b] close accepts a custom step id printed by list, and the thread#n form for it (feedback_cc2c7619)"
mk T-custom-steps nord '[{"id":"ns-1016c-1","step":"first custom","status":"open"},{"id":"ns-1016c-2","step":"second custom","status":"open"},{"id":"ns-1016c-3","step":"third custom","status":"open"}]'
g="$FX/workspace/threads/T-custom-steps.json"
HQ_ROOT="$FX" bash "$S" list | grep -q '^ns-1016c-3  third custom' || fail "custom id not listed"
HQ_ROOT="$FX" bash "$S" close ns-1016c-3 >/dev/null || fail "close by custom id printed by list"
[ "$(jq -r '.next_steps[2].status' "$g")" = done ] || fail "custom id step not closed: $(cat "$g")"
[ "$(jq -r '.next_steps[2].id' "$g")" = ns-1016c-3 ] || fail "custom id must be kept"
HQ_ROOT="$FX" bash "$S" close 'T-custom-steps#2' >/dev/null || fail "close by thread#n when step has a custom id"
[ "$(jq -r '.next_steps[1].status' "$g")" = done ] || fail "thread#n did not close step 2: $(cat "$g")"
[ "$(jq -r '.next_steps[0].status' "$g")" = open ] || fail "sibling untouched"
rc=0; HQ_ROOT="$FX" bash "$S" close ns-nope-9 >/dev/null 2>&1 || rc=$?; [ "$rc" = 3 ] || fail "unknown custom id rc $rc"
rc=0; HQ_ROOT="$FX" bash "$S" close 'T-custom-steps#7' >/dev/null 2>&1 || rc=$?; [ "$rc" = 3 ] || fail "out-of-range thread#n rc $rc"

echo "[4c] thread file name differs from thread_id: list and close resolve by thread_id (feedback_9e0d68a2)"
jq -n '{thread_id:"T-20260903-000000-auto", version:1, type:"checkpoint", created_at:"2026-09-03T00:00:00Z", updated_at:"2026-09-03T00:00:00Z", conversation_summary:"s", next_steps:["auto one","auto two"], metadata:{title:"auto", tags:[], company:["co-one"]}}' > "$FX/workspace/threads/T-autosave-renamed.json"
h="$FX/workspace/threads/T-autosave-renamed.json"
HQ_ROOT="$FX" bash "$S" list | grep -q '^T-20260903-000000-auto#1  auto one' || fail "synthetic id must use thread_id: $(HQ_ROOT="$FX" bash "$S" list)"
HQ_ROOT="$FX" bash "$S" close 'T-20260903-000000-auto#1' >/dev/null || fail "close by thread_id when file name differs"
[ "$(jq -r '.next_steps[0].status' "$h")" = done ] || fail "thread_id close: $(cat "$h")"
[ "$(jq -r '.next_steps[0].id' "$h")" = 'T-20260903-000000-auto#1' ] || fail "written id must use thread_id"
HQ_ROOT="$FX" bash "$S" close 'T-autosave-renamed#2' >/dev/null || fail "file-name thread#n form still accepted"
[ "$(jq -r '.next_steps[1].status' "$h")" = done ] || fail "file-name form: $(cat "$h")"

echo "[4d] bulk close: several ids, --ids-file, stdin; summary and rc 3 when one is missing (feedback_9e0d68a2)"
mk T-bulk co-one '["b1","b2","b3","b4","b5"]'
k="$FX/workspace/threads/T-bulk.json"
HQ_ROOT="$FX" bash "$S" close 'T-bulk#1' 'T-bulk#2' --as dropped --note bulk >/dev/null || fail "multi-id close rc"
[ "$(jq -r '[.next_steps[0,1].status] | join(",")' "$k")" = dropped,dropped ] || fail "multi-id: $(cat "$k")"
[ "$(jq -r '.next_steps[1].note' "$k")" = bulk ] || fail "note on bulk"
printf '# comment\n\nT-bulk#3\r\n  T-bulk#4  \n' > "$FX/ids.txt"
out="$(HQ_ROOT="$FX" bash "$S" close --ids-file "$FX/ids.txt")" || fail "ids-file rc"
grep -q '2 of 2 step(s) -> done; 0 not found' <<<"$out" || fail "summary: $out"
[ "$(jq -r '[.next_steps[2,3].status] | join(",")' "$k")" = done,done ] || fail "ids-file: $(cat "$k")"
rc=0; printf 'T-bulk#5\nT-bulk#99\n' | HQ_ROOT="$FX" bash "$S" close --ids-file - >"$FX/o" 2>/dev/null || rc=$?
[ "$rc" = 3 ] || fail "missing id in bulk must exit 3, got $rc"
[ "$(jq -r '.next_steps[4].status' "$k")" = done ] || fail "valid id in a partly bad batch still closes"
grep -q '1 of 2' "$FX/o" || fail "partial summary: $(cat "$FX/o")"
rc=0; HQ_ROOT="$FX" bash "$S" close --ids-file "$FX/nope.txt" >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "unreadable ids-file rc $rc"

echo "[5] handoff-finalize normalization jq (same expression) assigns ids and open status"
norm="$(jq -c --arg tid T-X '
  to_entries | map(.key as $k |
    (if (.value|type) == "string" then {step: .value} else .value end)
    | .id = (.id // ($tid + "#" + (($k + 1)|tostring)))
    | .status = (.status // "open")
  ) | map(del(.key))' <<<'["a",{"step":"b"},{"id":"keep#7","step":"c","status":"done"}]')"
[ "$norm" = '[{"step":"a","id":"T-X#1","status":"open"},{"step":"b","id":"T-X#2","status":"open"},{"id":"keep#7","step":"c","status":"done"}]' ] || fail "normalization: $norm"
grep -q 'NEXT_STEPS_NORMALIZED_JSON' "$ROOT/core/scripts/handoff-finalize.sh" || fail "handoff-finalize must use the normalized steps"
echo "handoff-open-steps: ok"
