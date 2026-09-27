#!/usr/bin/env bash
# refresh-pricing.sh — rewrite the shipped pricing copy from the live endpoint.
#
# Fetches GET https://hqapi.getindigo.ai/v1/pricing, writes it verbatim to
# core/knowledge/public/hq-core/pricing.json, and regenerates the numbers
# section of core/knowledge/public/hq-core/pricing-and-billing.md between
#   <!-- pricing:numbers:start --> and <!-- pricing:numbers:end -->
# Everything outside those markers is hand-written and left untouched.
#
# Usage: bash core/scripts/refresh-pricing.sh [--from-file <path>]
# Env:   HQ_PRICING_URL  override the endpoint URL
# Exit codes: 0 refreshed · 2 endpoint unreachable or invalid
#             3 usage, missing tool, or missing markers
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
URL="${HQ_PRICING_URL:-https://hqapi.getindigo.ai/v1/pricing}"
DIR="$ROOT/core/knowledge/public/hq-core"
JSON="$DIR/pricing.json"
MD="$DIR/pricing-and-billing.md"
FROM_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --from-file) FROM_FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "refresh-pricing: unknown argument: $1" >&2; exit 3 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "refresh-pricing: jq is required" >&2; exit 3; }
[ -f "$MD" ] || { echo "refresh-pricing: missing $MD" >&2; exit 3; }
grep -q '^<!-- pricing:numbers:start -->$' "$MD" && grep -q '^<!-- pricing:numbers:end -->$' "$MD" \
  || { echo "refresh-pricing: numbers markers not found in $MD" >&2; exit 3; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "$FROM_FILE" ]; then
  [ -f "$FROM_FILE" ] || { echo "refresh-pricing: file not found: $FROM_FILE" >&2; exit 3; }
  cp "$FROM_FILE" "$TMP/live.json"
else
  code="$(curl -sS --max-time 20 -o "$TMP/live.json" -w '%{http_code}' "$URL" 2>"$TMP/curl.err")" \
    || { echo "refresh-pricing: cannot reach $URL: $(tr -d '\n' <"$TMP/curl.err")" >&2; exit 2; }
  [ "$code" = "200" ] || { echo "refresh-pricing: $URL answered HTTP $code; nothing changed" >&2; exit 2; }
fi

jq -e '.version == 1 and (.plans | type == "array")' "$TMP/live.json" >/dev/null 2>&1 \
  || { echo "refresh-pricing: response is not a version-1 pricing statement; nothing changed" >&2; exit 2; }

jq -r '
  def usd: if . == null then "contract" elif . == (. | floor) then "$\(. | floor)" else "$\(.)" end;
  def lim: if . == null then "unlimited" else tostring end;
  def gb: if . == null then "unlimited" else "\(. / 1073741824 | floor) GB" end;
  "_Generated from pricing.json (statement generated \(.generatedAt)). Do not edit by hand; run core/scripts/refresh-pricing.sh._",
  "",
  "### Plans (per \(.interval), \(.currency | ascii_upcase))",
  "",
  "| Plan | Price | Included agents | Members | Secrets | Deployments | Storage | Integrations |",
  "|---|---|---|---|---|---|---|---|",
  (.plans[] | "| \(.displayName) | \(.monthlyUsd | usd) | \(.includedAgents) | \(.included.users | lim) | \(.included.secrets | lim) | \(.included.deployments | lim) | \(.included.storageBytes | gb) | \(.included.integrations | lim) |"),
  "",
  "### Agent boxes (per agent, per \(.interval))",
  "",
  "| Size | Instance | Price | Buyable today |",
  "|---|---|---|---|",
  (.agentRungs[] | "| \(.key)\(if .entry then " (default)" else "" end) | \(.instanceType) | \(.monthlyUsd | usd) | \(if .live then "yes" else "not yet" end) |"),
  "",
  "### Add-ons",
  "",
  "- Outpost: \(.addOns.outpost.monthlyUsd | usd) per \(.interval).",
  (if .addOns.meetingHours == null then "- Meeting hours: not priced yet."
   else "- Meeting hours: \(.addOns.meetingHours.perHourUsd | usd) per hour, \(.addOns.meetingHours.includedHours) hours included." end),
  (.addOns.notes[] | "- \(.)"),
  "",
  "### Legacy Workforce price",
  "",
  "- \(.grandfather.monthlyUsd | usd) per \(.interval), \(.grandfather.includedAgents) agents included: " +
    ([.grandfather.includedBoxes[] | "\(.count) \(.rung) (\(.instanceType))"] | join(", ")) + "."
' "$TMP/live.json" >"$TMP/numbers.md"

awk -v f="$TMP/numbers.md" '
  /^<!-- pricing:numbers:start -->$/ { print; while ((getline l < f) > 0) print l; skip = 1; next }
  /^<!-- pricing:numbers:end -->$/   { skip = 0 }
  !skip { print }
' "$MD" >"$TMP/md"

cp "$TMP/live.json" "$JSON"
cp "$TMP/md" "$MD"
echo "refresh-pricing: updated $JSON and the numbers section of $MD"
