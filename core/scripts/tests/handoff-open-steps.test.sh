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
