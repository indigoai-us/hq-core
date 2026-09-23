#!/usr/bin/env bash
# End-to-end: a local-only company with capture on gets a real brief from five
# session closes and one drop-in source, with no cloud access.
# The model steps (what /handoff chooses to capture, what process-source
# extracts) are replaced by fixed fixture lines; everything else is the real
# pipeline: knowledge-prefs -> ontology-candidate -> source-yaml-validate ->
# ontology-source-worklist -> ontology-garden -> ontology-brief.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; S="$here/.."
fail=0; pass=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL: $1 — want '$3' got '$2'"; fail=$((fail+1)); fi; }
ge() { if [ "$2" -ge "$3" ]; then pass=$((pass+1)); else echo "FAIL: $1 — want >= $3 got $2"; fail=$((fail+1)); fi; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/core/scripts" "$t/personal/settings" "$t/companies/solo/settings/knowledge" "$t/companies/solo/sources/notes"
cp "$S"/{knowledge-prefs.sh,ontology-candidate.sh,source-yaml-validate.sh,ontology-source-worklist.sh} "$t/core/scripts/"
printf 'companies:\n  solo:\n    prefix: sol\n' > "$t/companies/manifest.yaml"
printf 'slug: solo\ncloud: false\n' > "$t/companies/solo/company.yaml"
printf 'signals_capture: true\nontology_capture: true\n' > "$t/companies/solo/settings/knowledge/preferences.yaml"
# No hq CLI and no network on this path: point HQ_BIN at something that fails loudly.
printf '#!/usr/bin/env bash\necho "unexpected cloud call: $*" >> "%s/cloud-calls"; exit 1\n' "$t" > "$t/hq"; chmod +x "$t/hq"
export HQ_ROOT="$t" HQ_BIN="$t/hq"
W() { bash "$t/core/scripts/ontology-candidate.sh" write --company solo "$@" >/dev/null; }
me=owner@solo.dev

# Five session closes (what /handoff would capture).
for n in 1 2 3 4 5; do
  W --kind signal --type decision --audience company --source-ref "handoff:T-$n" --body "Session $n: Ada Park approved the Atlas pricing change"
  W --kind signal --type risk --audience "$me" --source-ref "handoff:T-$n" --body "Session $n: Atlas launch may slip if Northwind Bank delays review"
done
for e in "person:Ada Park" "project:Atlas" "company:Northwind Bank" "concept:Usage Pricing" "person:Ben Ito" "company:For" "concept:Calls"; do
  W --kind entity --type "${e%%:*}" --audience company --source-ref handoff:T-1 --body "${e#*:}"
done

# One drop-in source, explicit audience per item.
printf 'channel: notes\nkind: doc\narrives: drop\naudience_rule: explicit\nprocessor: ontology/process-source\nrun: local\nschedule: on-close\n' > "$t/companies/solo/sources/notes/source.yaml"
printf -- '---\naudience: [owner@solo.dev, ben@solo.dev]\n---\nBen Ito will own the Atlas migration.\n' > "$t/companies/solo/sources/notes/n1.md"
printf -- '---\n---\nNo audience here.\n' > "$t/companies/solo/sources/notes/n2.md"
wl="$(bash "$t/core/scripts/ontology-source-worklist.sh" --company solo --channel notes)"
check "no-audience item skipped" "$(printf '%s\n' "$wl" | jq -r 'select(.skip) | .skip')" "no-audience"
aud="$(printf '%s\n' "$wl" | jq -r 'select(.audience) | .audience | join(",")')"
W --kind signal --type commitment --audience "$aud" --source-ref notes:n1.md --body "Ben Ito will own the Atlas migration"
bash "$t/core/scripts/ontology-source-worklist.sh" --company solo --channel notes --mark-done "$t/companies/solo/sources/notes/n1.md"

node "$S/ontology-garden.mjs" --company solo --hq-root "$t" >/dev/null
brief="$(node "$S/ontology-brief.mjs" --company solo --hq-root "$t")"
C="$t/companies/solo"
ge "entities >= 5" "$(find "$C/ontology/entities" -name '*.md' | wc -l | tr -d ' ')" 5
ge "signals promoted >= 5" "$(find "$C/signals" -path '*/_candidates' -prune -o -name '*.md' -print | grep -v '/_' | wc -l | tr -d ' ')" 5
check "no stopword entities in brief" "$(printf '%s\n' "$brief" | grep -cE '^### (For|Calls|Context|Summary|Reason) ')" 0
ge "brief lists entities" "$(printf '%s\n' "$brief" | grep -c '^### ')" 5
check "session risk stays scoped" "$(find "$C/signals/risk" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" 0
check "source commitment scoped to its audience" "$(grep -l 'own the Atlas migration' "$C"/signals/@*/commitment/*.md | wc -l | tr -d ' ')" 1
check "no cloud calls" "$([ -f "$t/cloud-calls" ] && cat "$t/cloud-calls" || echo none)" none

echo "ontology-local-e2e: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
