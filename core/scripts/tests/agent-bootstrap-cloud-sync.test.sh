#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
new_agent="$ROOT/.claude/skills/new-agent/SKILL.md"
new_hire="$ROOT/.claude/skills/new-hire/SKILL.md"
checks=0

fail() { printf 'FAIL after %s assertions: %s\n' "$checks" "$*" >&2; exit 1; }

for skill in "$new_agent" "$new_hire"; do
  [[ -f "$skill" ]] || fail "skill missing: $skill"
  checks=$((checks + 1))
  if grep -Fq 'hq team-sync' "$skill"; then
    fail "cloud-backed onboarding still recommends hq team-sync: $skill"
  fi
  checks=$((checks + 1))
  grep -Fq 'hq sync pull --company {co}' "$skill" \
    || fail "company vault pull command missing: $skill"
  checks=$((checks + 1))
done

grep -Fq 'companies/{co}/' "$new_agent" \
  || fail 'new-agent probe must verify the company directory'
checks=$((checks + 1))

printf 'PASS: %s assertions; agent and hire onboarding use company sync and the agent probe checks its company directory\n' "$checks"
