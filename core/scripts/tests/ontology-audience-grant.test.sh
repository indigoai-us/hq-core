#!/usr/bin/env bash
# Tests for core/scripts/ontology-audience-grant.sh against a stub hq CLI.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; s="$here/../ontology-audience-grant.sh"
fail=0; pass=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL: $1 — want '$3' got '$2'"; fail=$((fail+1)); fi; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
A="$t/companies/acme"; mkdir -p "$A/signals/@k1/risk" "$A/ontology/facts/@k1/person" "$A/ontology/facts/@company/person" "$A/signals/decision" "$A/sources/meetings/@k1"
printf 'companies:\n  acme:\n    prefix: acm\n' > "$t/companies/manifest.yaml"
printf 'audience_key: k1\nprincipals: [a@x.com, B@x.com, outsider@y.com, prs_01ABC]\n' > "$A/signals/@k1/_audience.yaml"
# Stub hq: records grants in a ledger; acl reads the ledger back.
cat > "$t/hq" <<'STUB'
#!/usr/bin/env bash
L="$(dirname "$0")/ledger"
args="$*"
case "$args" in
  *"members --company acme list"*) printf 'EMAIL ROLE NAME\na@x.com member A\nb@x.com member B\n' ;;
  *" share "*) p="$(echo "$args" | sed 's/.* share \([^ ]*\) .*/\1/')"; w="$(echo "$args" | sed 's/.*--with \([^ ]*\).*/\1/')"
               [ "${STUB_DROP:-}" = "$w" ] || echo "$p $w" >> "$L" ;;
  *" acl "*) p="$(echo "$args" | sed 's/.* acl \([^ ]*\) .*/\1/')"
             jq -n --arg p "$p" --rawfile l "$L" '{direct: ($l | split("\n") | map(select(startswith($p+" "))) | map(split(" ")[1]) | map(if .=="@all" then {granteeType:"company-wide",granteeId:"@all",permission:"read"} else {granteeType:"email",granteeId:.,permission:"read"} end))}' ;;
esac
STUB
chmod +x "$t/hq"; : > "$t/ledger"
export HQ_ROOT="$t" HQ_BIN="$t/hq"

bash "$s" --company acme >/dev/null 2>&1; check "local-only exits 0" "$?" 0
check "local-only grants nothing" "$(wc -l < "$t/ledger" | tr -d ' ')" 0

printf 'slug: acme\ncloud: true\n' > "$A/company.yaml"
out="$(bash "$s" --company acme 2>&1)"; check "cloud run exits 0" "$?" 0
check "a granted on signals" "$(grep -c '^signals/@k1/\* a@x.com$' "$t/ledger")" 1
check "b lowercased + granted on facts" "$(grep -c '^ontology/facts/@k1/\* b@x.com$' "$t/ledger")" 1
check "sources scoped folder granted" "$(grep -c '^sources/meetings/@k1/\* a@x.com$' "$t/ledger")" 1
check "person uid granted" "$(grep -c "^signals/@k1/\\* prs_01ABC$" "$t/ledger")" 1
check "non-member skipped" "$(grep -c outsider "$t/ledger")" 0
check "company facts @all" "$(grep -c '^ontology/facts/@company/\* @all$' "$t/ledger")" 1
check "no @all on scoped" "$(grep '@k1' "$t/ledger" | grep -c '@all')" 0
check "no per-file grants" "$(grep -c '\.md ' "$t/ledger")" 0
# Regression (hq-pro #3662): a bare trailing-slash share is a private create-only
# folder, not a recursive share. Every grant must be the `/*` shared glob.
check "no bare trailing-slash grants" "$(grep -c '/ ' "$t/ledger")" 0
check "company type folder uses shared glob" "$(grep -c '^signals/decision/\* @all$' "$t/ledger")" 1
check "dry-run prints shared glob" "$(bash "$s" --company acme --dry-run 2>/dev/null | grep -cF 'would grant read signals/@k1/* -> a@x.com')" 1

: > "$t/ledger"; STUB_DROP=b@x.com bash "$s" --company acme >/dev/null 2>&1
check "failed readback exits 3" "$?" 3

echo "ontology-audience-grant: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
