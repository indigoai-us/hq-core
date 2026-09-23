#!/usr/bin/env bash
# Tests for core/scripts/knowledge-prefs.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; script="$here/../knowledge-prefs.sh"
fail=0; pass=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL: $1 — want '$3' got '$2'"; fail=$((fail+1)); fi; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/companies/acme/settings/knowledge" "$t/companies/bare" "$t/personal/settings"
export HQ_ROOT="$t"

check "default capture off" "$(bash "$script" get bare signals_capture)" false
check "default reader on" "$(bash "$script" get bare signals_enabled)" true

printf 'version: 1\nsignals_capture: true\n# ontology_capture: true\n' > "$t/companies/acme/settings/knowledge/preferences.yaml"
check "company override" "$(bash "$script" get acme signals_capture)" true
check "commented-out ignored" "$(bash "$script" get acme ontology_capture)" false

printf 'ontology_capture: true   # personal default\n' > "$t/personal/settings/knowledge-preferences.yaml"
check "personal fallback + inline comment" "$(bash "$script" get acme ontology_capture)" true
check "company beats personal" "$(bash "$script" get acme signals_capture)" true

bash "$script" get acme nope >/dev/null 2>&1; check "unknown field exits 2" "$?" 2
bash "$script" get ghost signals_capture >/dev/null 2>&1; check "missing company exits 2" "$?" 2
bash "$script" get >/dev/null 2>&1; check "bad usage exits 2" "$?" 2

echo "knowledge-prefs: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
