#!/usr/bin/env bash
# Ontology sync + seed + access wiring.
set -uo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
fail=0; pass=0; ok(){ pass=$((pass+1)); }; no(){ echo "FAIL: $1"; fail=$((fail+1)); }
for p in 'companies/\*/signals/_candidates/' 'companies/\*/ontology/_candidates/' 'companies/\*/ontology/_rejected/'; do
  grep -q "^$p\$" "$root/.hqignore" && ok || no ".hqignore missing $p"
done
for d in ontology/facts ontology/_candidates signals/_candidates ontology/entities/person sources/meetings; do
  [ -d "$root/companies/_template/$d" ] && ok || no "template missing $d"
done
grep -q 'sources/meetings/source.yaml' "$root/.claude/skills/newcompany/SKILL.md" && ok || no "/newcompany does not seed source.yaml"
grep -q 'never part of the member baseline' "$root/.claude/skills/team-access/SKILL.md" && ok || no "/team-access lacks ontology exclusion"
grep -q 'never in the' "$root/.claude/skills/designate-team/SKILL.md" && ok || no "/designate-team lacks ontology exclusion"
sed -n '/^## Release: TBD/,/^## Release: v/p' "$root/core/docs/hq/MIGRATION.md" | grep -q 'signals_capture' && ok || no "MIGRATION TBD lacks capture entry"
# designate-team baseline loop must not grant ontology/signals/sources
awk '/for prefix in/ {print}' "$root/.claude/skills/designate-team/SKILL.md" | grep -qE 'ontology|signals|sources' && no "baseline grants an ontology folder" || ok
echo "ontology-sync-wiring: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
