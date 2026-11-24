#!/usr/bin/env bash
# deploy-skill-no-shell-api-copy.test.sh — /deploy calls hq-deploy only through
# `hq deploy` (US-033 c1). The shell/curl copy of the API (deploy-api-request.sh)
# and the scripts built on it (list-apps.sh, site-events.sh) stay deleted, and
# no deploy or project-summary file sends a raw bearer token again.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEPLOY="$ROOT/.claude/skills/deploy"
SUMMARY="$ROOT/.claude/skills/project-summary"
SKILL="$DEPLOY/SKILL.md"
FAILS=0
fail() { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "  ok: $*"; }
[ -f "$SKILL" ] || { echo "FAIL: deploy skill is missing: $SKILL" >&2; exit 1; }

for script in deploy-api-request.sh list-apps.sh site-events.sh; do
  if [ -e "$DEPLOY/scripts/$script" ]; then
    fail "$script exists again under .claude/skills/deploy/scripts"
  else
    pass "$script is gone"
  fi
done

dirs=("$DEPLOY")
[ -d "$SUMMARY" ] && dirs+=("$SUMMARY")
hits="$(grep -rln -- 'deploy-api-request' "${dirs[@]}" 2>/dev/null || true)"
if [ -n "$hits" ]; then
  fail "files still reference deploy-api-request: $hits"
else
  pass "no deploy or project-summary file references deploy-api-request"
fi

if grep -nF 'HQ_DEPLOY_JWT=' "$SKILL" >/dev/null; then
  fail "SKILL.md still passes HQ_DEPLOY_JWT: $(grep -nF 'HQ_DEPLOY_JWT=' "$SKILL" | head -3)"
else
  pass "SKILL.md passes no HQ_DEPLOY_JWT"
fi

grep -Fq 'APPS_JSON=$(hq_deploy list "${HQ_SCOPE_ARGS[@]}" --json) || exit 1' "$SKILL" \
  && pass "the app list comes from hq deploy list and stops on failure" \
  || fail "APPS_JSON is not built from hq deploy list with a fail-closed exit"

grep -Fq 'hq_cli_floor_check deploy 5.345.246' "$SKILL" \
  && pass "Phase C checks the hq-cli version floor" \
  || fail "SKILL.md has no hq-cli 5.345.246 floor check"

if [ "$FAILS" -eq 0 ]; then
  echo "ALL PASS: deploy-skill-no-shell-api-copy"
  exit 0
fi
echo "FAILURES: $FAILS"
exit 1
