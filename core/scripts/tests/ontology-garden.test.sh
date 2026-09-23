#!/usr/bin/env bash
# Tests for core/scripts/ontology-garden.mjs
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; g="$here/../ontology-garden.mjs"; c="$here/../ontology-candidate.sh"
fail=0; pass=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL: $1 — want '$3' got '$2'"; fail=$((fail+1)); fi; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/companies/acme/settings/knowledge" "$t/personal/settings" "$t/core/scripts"
cp "$here/../knowledge-prefs.sh" "$c" "$t/core/scripts/"
printf 'signals_capture: true\nontology_capture: true\n' > "$t/companies/acme/settings/knowledge/preferences.yaml"
export HQ_ROOT="$t"
cand() { bash "$t/core/scripts/ontology-candidate.sh" write --company acme --source-ref test:1 "$@" >/dev/null; }
A="$t/companies/acme"

cand --kind entity --type company --audience company --body "Gmail"
cand --kind entity --type concept --audience company --body "Gmail"
cand --kind entity --type company --audience company --body "For"
cand --kind entity --type person --audience company --body "Jane Doe"
cand --kind signal --type decision --audience company --body "Jane Doe owns the Gmail migration"
cand --kind signal --type risk --audience "a@x.com,b@x.com" --body "Jane Doe may leave before launch"

node "$g" --company acme --hq-root "$t" >/dev/null
check "one Gmail entity" "$(find "$A/ontology/entities" -name 'gmail.md' | wc -l | tr -d ' ')" 1
check "Gmail is a company" "$(grep -c '^type: company' "$A/ontology/entities/company/gmail.md")" 1
check "no stopword entity" "$(find "$A/ontology/entities" -name 'for.md' | wc -l | tr -d ' ')" 0
check "type conflict + stopword rejected" "$(cat "$A"/ontology/_rejected/*.jsonl | wc -l | tr -d ' ')" 2
check "company signal promoted" "$(find "$A/signals/decision" -name '*.md' | wc -l | tr -d ' ')" 1
key="$(bash "$t/core/scripts/ontology-candidate.sh" key 'a@x.com,b@x.com')"
check "scoped signal under @key" "$(find "$A/signals/@$key/risk" -name '*.md' | wc -l | tr -d ' ')" 1
check "audience file lists principals" "$(grep -c 'principals: \[a@x.com, b@x.com\]' "$A/signals/@$key/_audience.yaml")" 1
check "no fact text in entity file" "$(grep -c 'leave before launch' "$A/ontology/entities/person/jane-doe.md")" 0
check "scoped fact in @key facts" "$(grep -c 'leave before launch' "$A/ontology/facts/@$key/person/jane-doe.md")" 1
check "company fact in @company facts" "$(grep -c 'Gmail migration' "$A/ontology/facts/@company/person/jane-doe.md")" 1
check "signal_count counts company only" "$(grep '^signal_count:' "$A/ontology/entities/person/jane-doe.md" | awk '{print $2}')" 1
check "candidates moved to _done" "$(find "$A/signals/_candidates" "$A/ontology/_candidates" -path '*/_done/*' -name '*.md' | wc -l | tr -d ' ')" 6
test -f "$A/ontology/.last-run"; check "watermark written" "$?" 0

snap() { (cd "$A" && find ontology signals -type f ! -name .last-run -exec shasum {} + | sort); }
before="$(snap)"; lr="$(cat "$A/ontology/.last-run")"
node "$g" --company acme --hq-root "$t" >/dev/null
check "second run is a no-op" "$(snap)" "$before"
check "watermark untouched when nothing processed" "$(cat "$A/ontology/.last-run")" "$lr"

echo "ontology-garden: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
