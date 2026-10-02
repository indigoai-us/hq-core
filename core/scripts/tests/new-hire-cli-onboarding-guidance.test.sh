#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/new-hire/SKILL.md"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
WORKFLOW="$ROOT/.github/workflows/pr-checks.yml"
grep -Fq 'bash core/scripts/tests/new-hire-cli-onboarding-guidance.test.sh' "$WORKFLOW" \
  || fail 'new-hire guidance regression is not registered in PR checks'


grep -Fq 'Steps 1–4 are the onboarding admin’s terminal tasks.' "$SKILL" \
  || fail 'new-hire does not identify who runs the provisioning commands'
grep -Fq 'The teammate does not need to run provisioning commands.' "$SKILL" \
  || fail 'new-hire does not separate admin setup from teammate setup'
grep -Fq 'hq login' "$SKILL" \
  || fail 'new-hire no longer gives the teammate the existing CLI setup path'
grep -Fq 'hq sync pull --company {co}' "$SKILL" \
  || fail 'new-hire no longer documents the existing terminal sync step'

printf 'new-hire CLI onboarding guidance: ok\n'
