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

# Usage card (2026-10-16 card): the shipped copy carries the contract shape.
jq -e '[.usage.meters[] | {(.id): .unitUsd}] | add == {"member-sync":0.10,"integration-call":0.05,"hq-mcp-call":0.05,"agent-run":0.05,"storage":2,"secret":0.5,"vault":5}' "$SHIPPED" >/dev/null
check "shipped copy carries the card's meter rates, vault included" 0 $?
jq -e '[.usage.meters[] | select(.waivedInTrial == true) | .id] == ["vault"]' "$SHIPPED" >/dev/null
check "only the vault fee is waived in the trial" 0 $?
jq -e '.usage.includedUsd == 10 and .usage.trial == {"days":30,"capUsd":500} and .usage.newSignupsFrom == "2026-10-16T18:00:00Z"' "$SHIPPED" >/dev/null
check "shipped copy carries \$10 included, 30-day trial capped at \$500, the cutover" 0 $?
jq -e '[.usage.boxes[] | [.size, .instanceType, .monthlyUsd]] == [["small","t3.small",100],["medium","t3.medium",200],["large","t3.large",400],["xlarge","t3.xlarge",800]]' "$SHIPPED" >/dev/null
check "shipped copy carries the four-size box ladder" 0 $?
jq -e '(.usage.free | sort) == ["background-ai","deploys","dms"] and .usage.domains == {"standardUsd":20,"premiumUsd":500}' "$SHIPPED" >/dev/null
check "deploys, DMs and background AI are free; domains unchanged" 0 $?
jq -e '[.signup.options[].id] == ["free","enterprise"] and .signup.selfHosted.url == "https://docs.hq.computer/hq/guide/use-hq-for-free/"' "$SHIPPED" >/dev/null
check "signup offers free and enterprise demo, with the self-hosted link" 0 $?
jq -e '[.plans[] | select(.id != "enterprise") | .newSignupsUntil] | length == 3 and all(. == "2026-10-16T18:00:00Z")' "$SHIPPED" >/dev/null
check "Starter, Workforce and Individual close to new signups at the cutover" 0 $?

drift_case() { # name, jq filter applied to the shipped copy, expected exit, expected field (optional)
  jq "$2" "$SHIPPED" >"$TMP/case.json"
  out="$(bash "$DRIFT" --live-file "$TMP/case.json" 2>&1)"; rc=$?
  check "$1" "$3" $rc
  if [ -n "${4:-}" ]; then
    case "$out" in *"$4"*) echo "ok   $1 names $4";; *) echo "FAIL $1 output: $out"; fail=1;; esac
  fi
}
drift_case "sync rate change exits 1" '(.usage.meters[] | select(.id == "member-sync") | .unitUsd) = 0.08' 1 "usage.meters.member-sync.unitUsd"
drift_case "vault fee change exits 1" '(.usage.meters[] | select(.id == "vault") | .unitUsd) = 10' 1 "usage.meters.vault.unitUsd"
drift_case "vault no longer waived in trial exits 1" '(.usage.meters[] | select(.id == "vault") | .waivedInTrial) = false' 1 "usage.meters.vault.waivedInTrial"
drift_case "dropping the vault meter exits 1" '.usage.meters |= map(select(.id != "vault"))' 1 "usage.meters.vault"
drift_case "included usage change exits 1" '.usage.includedUsd = 5' 1 "usage.includedUsd"
drift_case "trial cap change exits 1" '.usage.trial.capUsd = 250' 1 "usage.trial.capUsd"
drift_case "trial length change exits 1" '.usage.trial.days = 14' 1 "usage.trial.days"
drift_case "box price change exits 1" '(.usage.boxes[] | select(.size == "large") | .monthlyUsd) = 250' 1 "usage.boxes.large.monthlyUsd"
drift_case "box instance change exits 1" '(.usage.boxes[] | select(.size == "small") | .instanceType) = "t3.micro"' 1 "usage.boxes.small.instanceType"
drift_case "free list change exits 1" '.usage.free -= ["dms"]' 1 "usage.free"
drift_case "domain price change exits 1" '.usage.domains.premiumUsd = 400' 1 "usage.domains.premiumUsd"
drift_case "cutover change exits 1" '.usage.newSignupsFrom = "2026-10-19T00:00:00Z"' 1 "usage.newSignupsFrom"
drift_case "reopening Workforce to new signups exits 1" '(.plans[] | select(.id == "paid-500") | .newSignupsUntil) = null' 1 "plans.paid-500.newSignupsUntil"
drift_case "signup option label change exits 1" '.signup.options[0].label = "Start trial"' 1 "signup.options.free"
drift_case "self-hosted link change exits 1" '.signup.selfHosted.url = "https://example.com/"' 1 "signup.selfHosted.url"
drift_case "meter label and order are prose, not drift" '.usage.meters |= (reverse | map(.label = "edited"))' 0
drift_case "endpoint without the usage card exits 1" 'del(.usage)' 1 "usage: shipped=(present) live=(absent)"
case "$out" in *"does not publish: usage"*) echo "ok   missing usage card gets a plain message";; *) echo "FAIL missing-usage message: $out"; fail=1;; esac
drift_case "endpoint without signup options exits 1" 'del(.signup)' 1 "signup: shipped=(present) live=(absent)"
# A pre-card endpoint (no usage, signup or cutoffs) is drift against the carded copy.
jq 'del(.usage, .signup) | .plans |= map(del(.newSignupsUntil))' "$SHIPPED" >"$TMP/precard.json"
bash "$DRIFT" --live-file "$TMP/precard.json" >/dev/null 2>&1; check "pre-card endpoint exits 1" 1 $?

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
grep -q '^| Sync | \$0.10 | sync | no |$' "$MD"; check "refresh writes the usage meter table" 0 $?
grep -q '^| Vault | \$5.00 | vault-month | yes |$' "$MD"; check "refresh writes the vault fee, waived in trial" 0 $?
grep -q '^- Trial: 30 days, capped at \$500 of usage\.$' "$MD"; check "refresh writes the trial cap" 0 $?
grep -q '^| xlarge | t3.xlarge | \$800 |$' "$MD"; check "refresh writes the box ladder" 0 $?
grep -q '^- Use HQ free, self-hosted or on-prem: https://docs.hq.computer/hq/guide/use-hq-for-free/$' "$MD"; check "refresh writes the self-hosted link" 0 $?
grep -q '^| Workforce | .* | closed from 2026-10-16 |$' "$MD"; check "refresh marks Workforce closed to new signups" 0 $?
bash "$TMP/r/core/scripts/refresh-pricing.sh" --from-file "$TMP/bad.json" >/dev/null 2>&1
grep -q '^| Workforce | \$500 | 3 |' "$MD"; check "refresh rewrites the numbers table" 0 $?
grep -q '^## Hosted agents$' "$MD"; check "refresh keeps prose sections" 0 $?
cp "$TMP/r/core/knowledge/public/hq-core/pricing.json" "$TMP/before.json"
bash "$TMP/r/core/scripts/refresh-pricing.sh" --from-file "$TMP/precard.json" >/dev/null 2>&1
check "refresh refuses an endpoint that drops the usage card" 2 $?
cmp -s "$TMP/before.json" "$TMP/r/core/knowledge/public/hq-core/pricing.json"; check "refused refresh leaves pricing.json alone" 0 $?
rm -f "$TMP/r/core/knowledge/public/hq-core/pricing.json"
bash "$TMP/r/core/scripts/refresh-pricing.sh" --from-file "$TMP/precard.json" >/dev/null 2>&1; check "refresh accepts a pre-card statement on a pre-card copy" 0 $?
grep -q '^### Usage card' "$MD"; check "no usage section without a usage card" 1 $?
grep -q '^### Plans (per month, USD)$' "$MD"; check "pre-card statement keeps the plain Plans heading" 0 $?

exit $fail
