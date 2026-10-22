#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/deploy/SKILL.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$SKILL" ] || fail "deploy skill is missing: $SKILL"
AGENT_SECTION="$(awk '
  /^## Fleet agents \(machine identity\)/ { in_agent = 1; next }
  in_agent && /^## / { exit }
  in_agent { print }
' "$SKILL")"
[ -n "$AGENT_SECTION" ] || fail "deploy skill has no fleet agent section"

# Agent deploys are live since hq-deploy #230; the section must not say they are pending.
if printf '%s\n' "$AGENT_SECTION" | grep >/dev/null -F 'ships in the next hq-core release'; then
  fail "fleet agent section still says agent deploys are unreleased"
fi
pass "fleet agent section does not call agent deploys unreleased"

printf '%s\n' "$AGENT_SECTION" | grep >/dev/null -F 'external enrolled agents' \
  || fail "fleet agent section does not cover external enrolled agents"
printf '%s\n' "$AGENT_SECTION" | grep >/dev/null -F 'no admin-issued delegated operator token is needed' \
  || fail "fleet agent section does not say agents deploy without a delegated operator token"
printf '%s\n' "$AGENT_SECTION" | grep >/dev/null -F 'MACHINE_DELEGATION_REQUIRED' \
  || fail "fleet agent section does not explain MACHINE_DELEGATION_REQUIRED"
pass "fleet agent section documents external agents and the delegation error"
