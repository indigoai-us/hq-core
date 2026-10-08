#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/../skills-listing-budget.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/hq"
mkdir -p "$ROOT/.claude/skills/alpha" "$ROOT/.claude/skills/beta" \
  "$ROOT/.claude/skills/gamma" "$ROOT/.claude/skills/delta" \
  "$ROOT/.claude/skills/muted" "$ROOT/.claude/skills/fallback"
long_description="$(printf '%1200s' '' | tr ' ' a)"
{
  printf '%s\n' '---' 'name: alpha' 'description: >-' "  $long_description" \
    'when_to_use: Use as needed.' '---'
} > "$ROOT/.claude/skills/alpha/SKILL.md"
for skill in beta gamma delta muted; do
  { printf '%s\n' '---' "name: $skill" "description: $long_description" '---'; } \
    > "$ROOT/.claude/skills/$skill/SKILL.md"
done
printf '%s\n' 'Fallback summary text.' 'More skill instructions.' \
  > "$ROOT/.claude/skills/fallback/SKILL.md"
{ printf '%s\n' '---' 'name: delta' 'disable-model-invocation: true' \
    "description: $long_description" '---'; } > "$ROOT/.claude/skills/delta/SKILL.md"
cat > "$ROOT/.claude/settings.json" <<'JSON'
{
  "skillOverrides": {
    "gamma": "user-invocable-only",
    "muted": "name-only"
  }
}
JSON

out="$(bash "$GEN" "$ROOT")"
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -Fq 'Visible listing entries: 4'
printf '%s\n' "$out" | grep -Fq 'Listing characters (name + description): 2459'
printf '%s\n' "$out" | grep -Fq '200K estimate (2,000 characters): 459 description characters over budget; affected skill names depend on Claude invocation frequency'
printf '%s\n' "$out" | grep -Fq '1M estimate (10,000 characters): 0 description characters over budget; affected skill names depend on Claude invocation frequency'
printf '%s\n' '{"skillOverrides":{"gamma":"user-invocable-only","muted":"name-only"}}' \
  > "$ROOT/.claude/settings.json"
compact_out="$(bash "$GEN" "$ROOT")"
printf '%s\n' "$compact_out" | grep -Fq 'Visible listing entries: 4'
printf '%s\n' "$compact_out" | grep -Fq 'Listing characters (name + description): 2459'
echo 'skills-listing-budget.test.sh: passed'
