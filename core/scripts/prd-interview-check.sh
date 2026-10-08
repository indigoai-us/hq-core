#!/bin/bash
# prd-interview-check.sh — checks a prd.json interview count against the
# prd-minimum-questions policy (core/policies/prd-minimum-questions.md).
#
# Usage: prd-interview-check.sh <prd.json>
#
# Reads metadata.interview = {asked, skipped_known, skipped_fact, by_tier}.
# Passes when asked + skipped_known >= 10 and the asked questions span at
# least 2 of the 3 tiers. Otherwise prints "WARN: {N}/10 answered" (plus the
# tier shortfall) and exits 1. Exit 2 on a missing file, unreadable JSON, or
# missing count. Uses jq only (runtime scripts must not depend on python3).

set -euo pipefail

MIN_TOTAL=10
MIN_TIERS=2

[ $# -eq 1 ] || { echo "usage: prd-interview-check.sh <prd.json>" >&2; exit 2; }
[ -f "$1" ] || { echo "prd-interview-check.sh: no such file: $1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "prd-interview-check.sh: jq is required" >&2; exit 2; }

if ! counts="$(jq -r '
    (.metadata // {}).interview as $iv
    | if ($iv | type) != "object" then "missing"
      else
        (($iv.asked // 0 | tonumber) + ($iv.skipped_known // 0 | tonumber)) as $total
        | ([($iv.by_tier // {})[] | tonumber | select(. > 0)] | length) as $tiers
        | "\($total) \($tiers)"
      end' "$1" 2>/dev/null)"; then
  echo "prd-interview-check.sh: cannot parse $1 as JSON" >&2
  exit 2
fi

if [ "$counts" = "missing" ]; then
  echo "prd-interview-check.sh: metadata.interview missing" >&2
  exit 2
fi

total="${counts% *}"
tiers="${counts#* }"

problems=0
if [ "$total" -lt "$MIN_TOTAL" ]; then
  echo "WARN: $total/$MIN_TOTAL answered"
  problems=1
fi
if [ "$tiers" -lt "$MIN_TIERS" ]; then
  echo "WARN: $tiers/3 tiers covered (need $MIN_TIERS)"
  problems=1
fi
[ "$problems" -eq 0 ] || exit 1
echo "OK: $total/$MIN_TOTAL answered across $tiers tiers"
