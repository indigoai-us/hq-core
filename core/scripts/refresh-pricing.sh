#!/usr/bin/env bash
# refresh-pricing.sh — rewrite the shipped pricing copy from the live endpoint.
#
# Fetches GET /v1/pricing on the HQ API base (HQ_PRO_API_URL -> HQ_API_URL ->
# HQ_VAULT_API_URL -> https://hqapi.hq.computer), writes it verbatim to
# core/knowledge/public/hq-core/pricing.json, and regenerates:
#   core/knowledge/public/hq-core/pricing-and-billing.md between
#     <!-- pricing:numbers:start --> and <!-- pricing:numbers:end -->
#   core/knowledge/public/hq-core/plans-and-pricing.md between
#     <!-- pricing:meters:start --> and <!-- pricing:meters:end -->
#   core/workers/public/setup/skills/pricing.md between
#     <!-- pricing:meters:start --> and <!-- pricing:meters:end -->
# Everything outside those markers is hand-written and left untouched.
# A non-empty string displayText is the meter price; any other displayText
# falls through to that page's per-unit fallback.
#
# Usage: bash core/scripts/refresh-pricing.sh [--from-file <path>]
# Env:   HQ_PRICING_URL  override the endpoint URL
# Exit codes: 0 refreshed · 2 endpoint unreachable or invalid
#             3 usage, missing tool, or missing markers
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
URL="${HQ_PRICING_URL:-${HQ_PRO_API_URL:-${HQ_API_URL:-${HQ_VAULT_API_URL:-https://hqapi.hq.computer}}}/v1/pricing}"
DIR="$ROOT/core/knowledge/public/hq-core"
JSON="$DIR/pricing.json"
MD="$DIR/pricing-and-billing.md"
PLANS="$DIR/plans-and-pricing.md"
SKILL="$ROOT/core/workers/public/setup/skills/pricing.md"
FROM_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --from-file) FROM_FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "refresh-pricing: unknown argument: $1" >&2; exit 3 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "refresh-pricing: jq is required" >&2; exit 3; }
[ -f "$MD" ] || { echo "refresh-pricing: missing $MD" >&2; exit 3; }
[ -f "$PLANS" ] || { echo "refresh-pricing: missing $PLANS" >&2; exit 3; }
[ -f "$SKILL" ] || { echo "refresh-pricing: missing $SKILL" >&2; exit 3; }
grep -q '^<!-- pricing:numbers:start -->$' "$MD" && grep -q '^<!-- pricing:numbers:end -->$' "$MD" \
  || { echo "refresh-pricing: numbers markers not found in $MD" >&2; exit 3; }
grep -q '^<!-- pricing:meters:start -->$' "$PLANS" && grep -q '^<!-- pricing:meters:end -->$' "$PLANS" \
  || { echo "refresh-pricing: meters markers not found in $PLANS" >&2; exit 3; }
grep -q '^<!-- pricing:meters:start -->$' "$SKILL" && grep -q '^<!-- pricing:meters:end -->$' "$SKILL" \
  || { echo "refresh-pricing: meters markers not found in $SKILL" >&2; exit 3; }

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

# The usage card and signup options are published by the same endpoint. Refuse
# to drop them from the shipped copy when the endpoint has not published them yet.
for block in usage signup; do
  if [ -f "$JSON" ] && jq -e --arg b "$block" '.[$b] != null' "$JSON" >/dev/null 2>&1 \
    && ! jq -e --arg b "$block" '.[$b] != null' "$TMP/live.json" >/dev/null 2>&1; then
    echo "refresh-pricing: the endpoint publishes no \`$block\` block but the shipped copy has one; nothing changed" >&2
    echo "refresh-pricing: wait until the endpoint publishes the usage card, then run this again" >&2
    exit 2
  fi
done

jq -r '
  def usd: if . == null then "contract" elif . == (. | floor) then "$\(. | floor)" else "$\(.)" end;
  def lim: if . == null then "unlimited" else tostring end;
  def gb: if . == null then "unlimited" else "\(. / 1073741824 | floor) GB" end;
  def pad($n): tostring | until(length >= $n; "0" + .);
  # Two decimals, or three when the price has a tenth of a cent ($0.001).
  def cents: (. * 1000 | round) as $m
    | if $m % 10 == 0 then "$\($m / 1000 | floor).\($m % 1000 / 10 | floor | pad(2))"
      else "$\($m / 1000 | floor).\($m % 1000 | pad(3))" end;
  def free: {"deploys": "deploys", "dms": "DMs", "background-ai": "background AI"}[.] // .;
  "_Generated from pricing.json (statement generated \(.generatedAt)). Do not edit by hand; run core/scripts/refresh-pricing.sh._",
  "",
  (if .usage == null then empty else
    "### Usage card (new signups from \(.usage.newSignupsFrom[0:10]), card version \(.usage.version))",
    "",
    "| Meter | Price | Per | Waived in trial |",
    "|---|---|---|---|",
    (.usage.meters[] | "| \(.label) | \(if (.displayText | type) == "string" and .displayText != "" then .displayText else (.unitUsd | cents) end) | \(.unit) | \(if .waivedInTrial then "yes" else "no" end) |"),
    "",
    "- Included usage: \(.usage.includedUsd | usd) per \(.interval).",
    "- Trial: \(.usage.trial.days) days, capped at \(.usage.trial.capUsd | usd) of usage.",
    "- Free: \(.usage.free | map(free) | join(", ")).",
    "- Domains: \(.usage.domains.standardUsd | usd) standard, \(.usage.domains.premiumUsd | usd) premium, per \(.interval).",
    (if .usage.domains.purchase == null then empty else
      "- Domain purchase: registrar price plus \(.usage.domains.purchase.markupUsdPerYear | usd) a year, renewing \(.usage.domains.purchase.renewal) on the same basis\(if .usage.domains.purchase.chargedBeforeRenewal then ", charged before each renewal" else "" end)\(if .usage.domains.purchase.refundGraceDays then "; no refunds after a \(.usage.domains.purchase.refundGraceDays)-day grace period" else "" end)."
    end),
    "",
    "### Boxes on the usage card (per box, per \(.interval))",
    "",
    "| Size | Instance | Price |",
    "|---|---|---|",
    (.usage.boxes[] | "| \(.size) | \(.instanceType) | \(.monthlyUsd | usd) |"),
    ""
  end),
  (if ((.addOns.outpost.diskTiers // []) | length) == 0 then empty else
    "### Company Outpost disk (per Outpost, per \(.interval))",
    "",
    "A company Outpost that syncs the company files bills its box size plus the smallest disk tier that fits the company vault and 20 GB of headroom. The disk is charged once the Outpost confirms it is running. A company Outpost without company file sync gets a 30 GB disk at no charge.",
    "",
    "| Disk | Price |",
    "|---|---|",
    (.addOns.outpost.diskTiers[] | "| \(.diskGb) GB | \(.monthlyUsd | usd) |"),
    ""
  end),
  (if .signup == null then empty else
    "### Signup",
    "",
    (.signup.options[] | "- \(.label) (`\(.id)`)"),
    (if .signup.selfHosted == null then empty else "- \(.signup.selfHosted.label): \(.signup.selfHosted.url)" end),
    ""
  end),
  "### \(if .usage == null then "Plans" else "Legacy plans" end) (per \(.interval), \(.currency | ascii_upcase))",
  "",
  "| Plan | Price | Included agents | Members | Secrets | Deployments | Storage | Integrations | New signups |",
  "|---|---|---|---|---|---|---|---|---|",
  (.plans[] | "| \(.displayName) | \(.monthlyUsd | usd) | \(.includedAgents) | \(.included.users | lim) | \(.included.secrets | lim) | \(.included.deployments | lim) | \(.included.storageBytes | gb) | \(.included.integrations | lim) | \(if (.newSignupsUntil // null) == null then "open" else "closed from \(.newSignupsUntil[0:10])" end) |"),
  "",
  "### \(if .usage == null then "Agent boxes" else "Agent boxes on legacy plans" end) (per agent, per \(.interval))",
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

if jq -e '.usage.meters != null' "$TMP/live.json" >/dev/null 2>&1; then
  jq -r '
    def usd: if . == null then "contract" elif . == (. | floor) then "$\(. | floor)" else "$\(.)" end;
    def pad($n): tostring | until(length >= $n; "0" + .);
    def cents: (. * 1000 | round) as $m
      | if $m % 10 == 0 then "$\($m / 1000 | floor).\($m % 1000 / 10 | floor | pad(2))"
        else "$\($m / 1000 | floor).\($m % 1000 | pad(3))" end;
    def has_display:
      (.displayText | type) == "string" and .displayText != "";
    def plans_label:
      {"member-sync": "Sync (moved files, per leg)",
       "integration-call": "Gateway call (integrations and external MCP through HQ)",
       "hq-mcp-call": "HQ MCP call",
       "agent-run": "Agent run",
       "storage": "Storage",
       "secret": "Secret",
       "vault": "Vault"}[.id] // .label;
    def plans_fallback:
      if .id == "storage" or .id == "secret" then "\(.unitUsd | cents) per \(.unit)"
      elif .id == "vault" then
        "\(.unitUsd | usd) per vault per month, for each company vault and each personal vault"
        + (if .waivedInTrial then "; waived during the trial" else "" end)
      elif .id == "meeting-hour" then "\(.unitUsd | cents) per \(.unit)"
      else (.unitUsd | cents)
      end;
    def plans_price:
      if has_display then .displayText else plans_fallback end;
    .usage.meters[] | "| \(plans_label) | \(plans_price) |"
  ' "$TMP/live.json" >"$TMP/plans-meters.md"
  jq -r '
    def usd: if . == null then "contract" elif . == (. | floor) then "$\(. | floor)" else "$\(.)" end;
    def pad($n): tostring | until(length >= $n; "0" + .);
    def cents: (. * 1000 | round) as $m
      | if $m % 10 == 0 then "$\($m / 1000 | floor).\($m % 1000 / 10 | floor | pad(2))"
        else "$\($m / 1000 | floor).\($m % 1000 | pad(3))" end;
    def has_display:
      (.displayText | type) == "string" and .displayText != "";
    def skill_phrase:
      {"member-sync": "sync",
       "integration-call": "a call to a connected app or an outside MCP server through HQ",
       "hq-mcp-call": "an HQ MCP call",
       "agent-run": "an agent run",
       "storage": "files",
       "secret": "keys",
       "vault": "each company vault and each personal vault",
       "meeting-hour": "a meeting hour"}[.id] // .label;
    def skill_fallback:
      if .id == "member-sync" then "\(.unitUsd | cents) per moved file, per leg"
      elif .id == "storage" then "\(.unitUsd | cents) per GB a month"
      elif .id == "secret" then "\(.unitUsd | cents) per key a month"
      elif .id == "vault" then
        "\(.unitUsd | usd) a month (part of the " + "$" + "10\n  included usage"
        + (if .waivedInTrial then "; free during the trial)" else ")" end)
      elif .id == "meeting-hour" then "\(.unitUsd | cents) an hour"
      else (.unitUsd | cents)
      end;
    def skill_price:
      if has_display then .displayText else skill_fallback end;
    .usage.meters[] | "- \(skill_phrase): \(skill_price)"
  ' "$TMP/live.json" >"$TMP/skill-meters.md"
else
  : >"$TMP/plans-meters.md"
  : >"$TMP/skill-meters.md"
fi

awk -v f="$TMP/numbers.md" '
  /^<!-- pricing:numbers:start -->$/ { print; while ((getline l < f) > 0) print l; skip = 1; next }
  /^<!-- pricing:numbers:end -->$/   { skip = 0 }
  !skip { print }
' "$MD" >"$TMP/md"

awk -v f="$TMP/plans-meters.md" '
  /^<!-- pricing:meters:start -->$/ { print; while ((getline l < f) > 0) print l; skip = 1; next }
  /^<!-- pricing:meters:end -->$/   { skip = 0 }
  !skip { print }
' "$PLANS" >"$TMP/plans.md"

awk -v f="$TMP/skill-meters.md" '
  /^<!-- pricing:meters:start -->$/ { print; while ((getline l < f) > 0) print l; skip = 1; next }
  /^<!-- pricing:meters:end -->$/   { skip = 0 }
  !skip { print }
' "$SKILL" >"$TMP/skill.md"

cp "$TMP/live.json" "$JSON"
cp "$TMP/md" "$MD"
cp "$TMP/plans.md" "$PLANS"
cp "$TMP/skill.md" "$SKILL"
echo "refresh-pricing: updated $JSON, the numbers section of $MD, the meters section of $PLANS, and the meters section of $SKILL"
