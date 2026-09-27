#!/usr/bin/env bash
# Regression for check-pricing-drift.sh and refresh-pricing.sh (offline).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DRIFT="$ROOT/core/scripts/check-pricing-drift.sh"
SHIPPED="$ROOT/core/knowledge/public/hq-core/pricing.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (expected $2, got $3)"; fail=1; fi; }

bash "$DRIFT" --live-file "$SHIPPED" >/dev/null 2>&1; check "identical copy exits 0" 0 $?

jq '.generatedAt = "2030-01-01T00:00:00.000Z" | .billingRules[0].text = "edited"' "$SHIPPED" >"$TMP/prose.json"
bash "$DRIFT" --live-file "$TMP/prose.json" >/dev/null 2>&1; check "prose-only change is not drift" 0 $?

jq '(.plans[] | select(.id == "paid-500") | .includedAgents) = 3' "$SHIPPED" >"$TMP/bad.json"
out="$(bash "$DRIFT" --live-file "$TMP/bad.json" 2>&1)"; rc=$?
check "Workforce includes 3 agents exits 1" 1 $rc
case "$out" in *"plans.paid-500.includedAgents"*) echo "ok   drift names the field";; *) echo "FAIL drift output: $out"; fail=1;; esac

jq '.agentRungs[0].monthlyUsd = 120' "$SHIPPED" >"$TMP/rung.json"
bash "$DRIFT" --live-file "$TMP/rung.json" >/dev/null 2>&1; check "rung price change exits 1" 1 $?

HQ_PRICING_URL="http://127.0.0.1:9/v1/pricing" bash "$DRIFT" >/dev/null 2>&1; check "unreachable endpoint exits 2" 2 $?
HQ_PRICING_DRIFT_ALLOW_UNREACHABLE=1 HQ_PRICING_URL="http://127.0.0.1:9/v1/pricing" bash "$DRIFT" >/dev/null 2>&1
check "unreachable with allow flag exits 0" 0 $?

# refresh-pricing.sh regenerates only the marked section, idempotently.
mkdir -p "$TMP/r/core/scripts" "$TMP/r/core/knowledge/public/hq-core"
cp "$ROOT/core/scripts/refresh-pricing.sh" "$TMP/r/core/scripts/"
cp "$ROOT/core/knowledge/public/hq-core/pricing-and-billing.md" "$TMP/r/core/knowledge/public/hq-core/"
MD="$TMP/r/core/knowledge/public/hq-core/pricing-and-billing.md"
bash "$TMP/r/core/scripts/refresh-pricing.sh" --from-file "$SHIPPED" >/dev/null 2>&1; check "refresh exits 0" 0 $?
cmp -s "$MD" "$ROOT/core/knowledge/public/hq-core/pricing-and-billing.md"; check "shipped md matches its pricing.json" 0 $?
bash "$TMP/r/core/scripts/refresh-pricing.sh" --from-file "$TMP/bad.json" >/dev/null 2>&1
grep -q '^| Workforce | \$500 | 3 |' "$MD"; check "refresh rewrites the numbers table" 0 $?
grep -q '^## Hosted agents$' "$MD"; check "refresh keeps prose sections" 0 $?

exit $fail
