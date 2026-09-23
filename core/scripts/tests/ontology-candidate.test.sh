#!/usr/bin/env bash
# Tests for core/scripts/ontology-candidate.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; s="$here/../ontology-candidate.sh"
fail=0; pass=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL: $1 — want '$3' got '$2'"; fail=$((fail+1)); fi; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/companies/acme/settings/knowledge" "$t/companies/off" "$t/personal/settings" "$t/core/scripts"
cp "$here/../knowledge-prefs.sh" "$here/../ontology-candidate.sh" "$t/core/scripts/"
export HQ_ROOT="$t"
printf 'signals_capture: true\nontology_capture: true\n' > "$t/companies/acme/settings/knowledge/preferences.yaml"
count() { find "$t/companies/$1/$2/_candidates" -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }
w() { bash "$s" write --company "$1" --kind "$2" --type "$3" --audience "$4" --source-ref handoff:T-1 --body "$5"; }

w acme signal decision company "Ship the local ontology worker" >/dev/null
w acme signal decision company "Ship the local ontology worker" >/dev/null
check "idempotent" "$(count acme signals)" 1
w acme signal decision company "ship the   LOCAL ontology worker" >/dev/null
check "normalized body dedups" "$(count acme signals)" 1

check "audience key order-insensitive" "$(bash "$s" key 'a@x.com,b@x.com')" "$(bash "$s" key ' B@x.com, a@x.com')"
check "uid case preserved in key" "$(bash "$s" key 'prs_01ABC')" "$(printf '%s' prs_01ABC | shasum -a 256 | cut -c1-16)"
check "uid case matters" "$([ "$(bash "$s" key prs_01ABC)" != "$(bash "$s" key prs_01abc)" ] && echo differ)" differ
check "company key" "$(bash "$s" key company)" company
w acme signal decision "a@x.com,b@x.com" "Ship the local ontology worker" >/dev/null
check "audience is part of dedup" "$(count acme signals)" 2
f="$(grep -rlE 'audience_key: [0-9a-f]{16}$' "$t/companies/acme/signals/_candidates")"
check "scoped candidate lists principals" "$(grep -c '^audience: \[a@x.com, b@x.com\]' "$f")" 1

out="$(w off signal risk company "anything")"
check "disabled switch is a no-op" "$out" "disabled for off (signals_capture=false)"
check "disabled writes nothing" "$(count off signals)" 0

w acme signal gossip company "x" >/dev/null 2>&1; check "bad signal type exits 2" "$?" 2
w acme entity person company "" >/dev/null 2>&1; check "empty body exits 2" "$?" 2
w acme entity person company "Jane Doe" >/dev/null
check "entity candidate written" "$(count acme ontology)" 1

echo "ontology-candidate: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
