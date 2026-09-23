#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; b="$here/../ontology-brief.mjs"
fail=0; pass=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL: $1 — want '$3' got '$2'"; fail=$((fail+1)); fi; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
A="$t/companies/acme"; mkdir -p "$A"
check "empty brief" "$(node "$b" --company acme --hq-root "$t" | grep -c 'no local ontology yet')" 1
for n in 1 2 3 4 5; do mkdir -p "$A/ontology/entities/person"; printf -- '---\ntype: person\ncanonical_name: Person %s\nslug: person-%s\nsignal_count: 0\n---\n' $n $n > "$A/ontology/entities/person/person-$n.md"; done
mkdir -p "$A/ontology/facts/@company/person" "$A/signals/decision" "$A/signals/@k1/risk"
printf -- '---\nentity: person-1\n---\n- [decision] Person 1 owns launch (signal abc)\n' > "$A/ontology/facts/@company/person/person-1.md"
printf -- '---\ntype: decision\ncanonical_content: "Person 1 owns launch"\ncreated_at: %s\n---\nx\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$A/signals/decision/s1.md"
out="$(node "$b" --company acme --hq-root "$t")"
check "lists all 5 entities" "$(printf '%s' "$out" | grep -c '^### Person')" 5
check "company fact shown" "$(printf '%s' "$out" | grep -c 'owns launch (signal abc) _(company)_')" 1
check "scoped fact absent when folder absent" "$(printf '%s' "$out" | grep -c 'leave before launch')" 0
mkdir -p "$A/ontology/facts/@k1/person"; printf -- '---\nentity: person-1\n---\n- [risk] Person 1 may leave before launch (signal def)\n' > "$A/ontology/facts/@k1/person/person-1.md"
check "scoped fact shown + tagged when present" "$(node "$b" --company acme --hq-root "$t" | grep -c 'leave before launch (signal def) _(scoped)_')" 1
before="$(find "$A" -type f | sort | shasum)"; node "$b" --company acme --hq-root "$t" >/dev/null
check "writes nothing" "$(find "$A" -type f | sort | shasum)" "$before"
echo "ontology-brief: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
