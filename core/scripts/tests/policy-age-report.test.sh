#!/usr/bin/env bash
# hq-core: public
# Regression tests for core/scripts/policy-age-report.sh (2026-09-07).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"; S="$ROOT/core/scripts/policy-age-report.sh"
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$FX/core/policies" "$FX/personal/policies" "$FX/workspace/orchestrator/policy-trigger-state" "$FX/core/scripts"
: > "$FX/core/scripts/exists.sh"
NOW=1800000000   # fixed "now"
day=86400
pol() { # <file> <id> <created YYYY-MM-DD> <source> <version> <rule>
  printf -- '---\nid: %s\ntitle: t\nenforcement: hard\ncreated: %s\nsource: %s\nversion: %s\nwhen: always\n---\n\n## Rule\n\n%s\n' "$2" "$3" "$4" "$5" "$6" > "$1"
}
pol "$FX/personal/policies/fresh-used.md"  fresh-used  2026-01-01 session-learning 1 'Run `core/scripts/exists.sh` first.'
pol "$FX/personal/policies/never-old.md"   never-old   2025-01-01 user-correction  1 'Something nobody triggers.'
pol "$FX/personal/policies/dormant.md"     dormant     2025-01-01 migration        3 'Old but once used.'
pol "$FX/core/policies/stale-ref.md"       stale-ref   2026-01-01 consolidation    2 'Always call `core/scripts/gone-forever.sh` and `core/scripts/exists.sh`.'
pol "$FX/personal/policies/new-single.md"  new-single  2026-01-01 session-learning 1 'Brand new one-off.'
# ledgers: fresh-used fired in 3 sessions (one recent), dormant fired long ago
mkl() { printf '%s\n' "$2" > "$FX/workspace/orchestrator/policy-trigger-state/$1.txt"; touch -d "@$3" "$FX/workspace/orchestrator/policy-trigger-state/$1.txt" 2>/dev/null || touch -t "$(date -u -r "$3" +%Y%m%d%H%M)" "$FX/workspace/orchestrator/policy-trigger-state/$1.txt"; }
mkl s1 $'fresh-used\ndormant' $((NOW - 200*day))
mkl s2 'fresh-used' $((NOW - 100*day))
mkl s3 'fresh-used' $((NOW - 2*day))
# created dates relative to NOW: compute ages the script will see
export HQ_POLICY_REPORT_NOW_EPOCH="$NOW"
out="$(HQ_ROOT="$FX" bash "$S" --json)"
get() { jq -r --arg id "$1" ".[] | select(.id==\$id) | $2" <<<"$out"; }
echo "[1] usage counts and last-fired"
[ "$(get fresh-used .fired)" = 3 ] || fail "fresh-used fired: $(get fresh-used .fired)"
[ "$(get never-old .fired)" = 0 ] || fail "never-old fired"
[ "$(get dormant .fired)" = 1 ] || fail "dormant fired"
echo "[2] candidate classes"
get never-old '.candidate_classes|join(",")' | grep -q 'never-fired' || fail "never-old should be never-fired: $(get never-old .)"
get never-old '.candidate_classes|join(",")' | grep -q 'single-incident-old' || fail "never-old is a single incident, old"
get dormant '.candidate_classes|join(",")' | grep -q 'dormant' || fail "dormant class"
get stale-ref '.stale_refs|join(",")' | grep -q 'gone-forever.sh' || fail "stale ref not detected: $(get stale-ref .)"
get stale-ref '.stale_refs|join(",")' | grep -q 'exists.sh' && fail "existing ref flagged as stale"
[ "$(get fresh-used '.candidate_classes|length')" = 0 ] || fail "fresh-used must not be a candidate: $(get fresh-used .)"
echo "[3] --candidates human output lists only candidates"
h="$(HQ_ROOT="$FX" bash "$S" --candidates)"
grep -q 'never-old' <<<"$h" && grep -q 'stale-ref' <<<"$h" || fail "candidates missing: $h"
grep -q 'fresh-used' <<<"$h" && fail "non-candidate listed: $h"
grep -qE '^policy-age-report: 5 policies, 3 never fired' <<<"$h" || fail "summary line: $(head -1 <<<"$h")"
echo "[4] thresholds are tunable"
n="$(HQ_ROOT="$FX" bash "$S" --json --candidates --min-age 100000 --dormant-days 100000 --incident-days 100000 | jq 'map(select(.candidate_classes|index("never-fired") or index("dormant") or index("single-incident-old")))|length')"
[ "$n" = 0 ] || fail "thresholds ignored: $n"
echo "policy-age-report: ok"
