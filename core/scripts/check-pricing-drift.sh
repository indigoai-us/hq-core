#!/usr/bin/env bash
# check-pricing-drift.sh — fail when the shipped pricing copy disagrees with
# the live pricing endpoint.
#
# Compares core/knowledge/public/hq-core/pricing.json against
# GET /v1/pricing on the HQ API base (HQ_PRO_API_URL -> HQ_API_URL ->
# HQ_VAULT_API_URL -> https://hqapi.hq.computer) on every plan price, allowance,
# new-signup cutoff, agent rung, add-on price, the grandfather rule, the usage
# card (version, cutover, included usage, trial, every meter including the
# vault fee, the box ladder, free items, domains) and the signup options.
# Meter labels, other prose fields and generatedAt are ignored.
#
# Usage: bash core/scripts/check-pricing-drift.sh [--live-file <path>]
# Env:
#   HQ_PRICING_URL                       override the endpoint URL
#   HQ_PRICING_FILE                      override the shipped copy path
#   HQ_PRICING_DRIFT_ALLOW_UNREACHABLE=1 exit 0 with a warning when the
#                                        endpoint cannot be reached
#
# Exit codes: 0 no drift · 1 drift (each differing field is printed)
#             2 endpoint unreachable or invalid · 3 usage or missing tool
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
URL="${HQ_PRICING_URL:-${HQ_PRO_API_URL:-${HQ_API_URL:-${HQ_VAULT_API_URL:-https://hqapi.hq.computer}}}/v1/pricing}"
SHIPPED="${HQ_PRICING_FILE:-$ROOT/core/knowledge/public/hq-core/pricing.json}"
LIVE_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --live-file) LIVE_FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "check-pricing-drift: unknown argument: $1" >&2; exit 3 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "check-pricing-drift: jq is required" >&2; exit 3; }
[ -f "$SHIPPED" ] || { echo "check-pricing-drift: shipped copy not found: $SHIPPED" >&2; exit 3; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unreachable() {
  echo "check-pricing-drift: cannot read the live pricing endpoint ($URL): $1" >&2
  if [ "${HQ_PRICING_DRIFT_ALLOW_UNREACHABLE:-0}" = "1" ]; then
    echo "check-pricing-drift: WARNING: drift not checked (HQ_PRICING_DRIFT_ALLOW_UNREACHABLE=1)" >&2
    exit 0
  fi
  exit 2
}

if [ -n "$LIVE_FILE" ]; then
  [ -f "$LIVE_FILE" ] || { echo "check-pricing-drift: live file not found: $LIVE_FILE" >&2; exit 3; }
  cp "$LIVE_FILE" "$TMP/live.json"
else
  code="$(curl -sS --max-time 20 -o "$TMP/live.json" -w '%{http_code}' "$URL" 2>"$TMP/curl.err")" \
    || unreachable "$(tr -d '\n' <"$TMP/curl.err")"
  [ "$code" = "200" ] || unreachable "HTTP $code"
fi

jq -e '.version == 1 and (.plans | type == "array")' "$TMP/live.json" >/dev/null 2>&1 \
  || unreachable "response is not a version-1 pricing statement"

# Projection of the fields that carry a price, allowance, rung, add-on, the
# usage card, the signup options, or a plan's new-signup cutoff. A statement
# without a usage or signup block projects it to null, so a block present on
# one side only is drift.
PROJECT='{
  currency, interval,
  plans: ([.plans[] | {key: .id, value: {monthlyUsd, includedAgents, included, hardLimits,
                                          newSignupsUntil: (.newSignupsUntil // null)}}] | from_entries),
  usage: (.usage | if . == null then null else {
    version, newSignupsFrom, includedUsd,
    trial: {days: .trial.days, capUsd: .trial.capUsd},
    meters: ([.meters[] | {key: .id, value: {unit, unitUsd, waivedInTrial: (.waivedInTrial // false)}}] | from_entries),
    boxes: ([.boxes[] | {key: .size, value: {instanceType, monthlyUsd}}] | from_entries),
    free: (.free | sort),
    domains: {standardUsd: .domains.standardUsd, premiumUsd: .domains.premiumUsd}
  } end),
  signup: (.signup | if . == null then null else {
    options: ([.options[] | {key: .id, value: .label}] | from_entries),
    selfHosted: (.selfHosted | if . == null then null else {label, url} end)
  } end),
  agentRungs: ([.agentRungs[] | {key: .key, value: {instanceType, monthlyUsd, live, entry}}] | from_entries),
  addOns: {outpost: .addOns.outpost.monthlyUsd,
           meetingHours: (.addOns.meetingHours | if . == null then null else {perHourUsd, includedHours} end)},
  grandfather: {monthlyUsd: .grandfather.monthlyUsd, includedAgents: .grandfather.includedAgents,
                includedBoxes: .grandfather.includedBoxes}
}'

jq -S "$PROJECT" "$SHIPPED" >"$TMP/a.json" || { echo "check-pricing-drift: shipped copy is not valid pricing JSON" >&2; exit 3; }
jq -S "$PROJECT" "$TMP/live.json" >"$TMP/b.json"

diffs="$(jq -rn --slurpfile a "$TMP/a.json" --slurpfile b "$TMP/b.json" '
  ($a[0]) as $A | ($b[0]) as $B
  | ([$A, $B] | map([paths(type != "object" and type != "array")]) | add | unique) as $ps
  # A block or entry missing on one side is reported once, at the shortest
  # path where it is absent, not once per field inside it.
  | [ $ps[] as $p
      | select(($A | getpath($p)) != ($B | getpath($p)))
      | (first(range(1; ($p | length) + 1) as $i | $p[:$i] as $q
               | select(($A | getpath($q)) == null or ($B | getpath($q)) == null) | $q) // $p)
    ] | unique | .[]
  | . as $r | ($A | getpath($r)) as $x | ($B | getpath($r)) as $y
  | def show: if type == "object" or type == "array" then "(present)" elif . == null then "(absent)" else tojson end;
    "\($r | map(tostring) | join(".")): shipped=\($x | show) live=\($y | show)"
')"

if [ -n "$diffs" ]; then
  echo "check-pricing-drift: DRIFT between $SHIPPED and $URL" >&2
  printf '%s\n' "$diffs" | sed 's/^/  /' >&2
  missing=""
  for block in usage signup; do
    if jq -e --arg b "$block" '.[$b] == null' "$TMP/b.json" >/dev/null \
      && jq -e --arg b "$block" '.[$b] != null' "$TMP/a.json" >/dev/null; then
      missing="$missing $block"
    fi
  done
  if [ -n "$missing" ]; then
    echo "check-pricing-drift: the live endpoint does not publish:$missing. The shipped copy carries the usage card" >&2
    echo "  ahead of the endpoint. This check passes once the endpoint is deployed with the card and" >&2
    echo "  core/scripts/refresh-pricing.sh has been run against it." >&2
  else
    echo "Run core/scripts/refresh-pricing.sh to update the shipped copy." >&2
  fi
  exit 1
fi
echo "check-pricing-drift: OK (shipped pricing.json matches the live endpoint)"
