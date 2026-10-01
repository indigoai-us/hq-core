#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LOCK="$ROOT/core/scripts/knowledge-pulse-lock.sh"
SKILL="$ROOT/.claude/skills/knowledge-pulse/SKILL.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if [[ ! -f "$LOCK" ]]; then
  fail "atomic knowledge-pulse lock helper is missing"
fi

claim_root="$tmp/claims"
first="$(bash "$LOCK" claim "$claim_root" indigo 2026-09-30)"
second="$(bash "$LOCK" claim "$claim_root" indigo 2026-09-30)"
[[ "$first" == "claimed" ]] || fail "first claim returned '$first'"
[[ "$second" == "already-claimed" ]] || fail "same-day claim returned '$second'"

different_company="$(bash "$LOCK" claim "$claim_root" another-company 2026-09-30)"
different_day="$(bash "$LOCK" claim "$claim_root" indigo 2026-10-01)"
[[ "$different_company" == "claimed" ]] || fail "different company was not admitted"
[[ "$different_day" == "claimed" ]] || fail "different day was not admitted"

race_root="$tmp/race"
bash "$LOCK" claim "$race_root" race-company 2026-09-30 > "$tmp/claim-a" &
pid_a=$!
bash "$LOCK" claim "$race_root" race-company 2026-09-30 > "$tmp/claim-b" &
pid_b=$!
wait "$pid_a"
wait "$pid_b"
printf '%s\n' "$(cat "$tmp/claim-a")" "$(cat "$tmp/claim-b")" | sort > "$tmp/claims-sorted"
printf '%s\n' already-claimed claimed > "$tmp/expected"
cmp -s "$tmp/expected" "$tmp/claims-sorted" || fail "concurrent claims did not admit exactly one pulse"

grep -Fq 'bash core/scripts/knowledge-pulse-lock.sh claim workspace/reports/knowledge-pulse/.claims' "$SKILL" ||
  fail "knowledge-pulse Step 0 does not use the atomic claim"
grep -Fq 'already-claimed' "$SKILL" ||
  fail "knowledge-pulse does not skip a claimed company/date"

echo "knowledge-pulse-lock: passed"
