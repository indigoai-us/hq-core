#!/usr/bin/env bash
# Regression: /deploy org-resolution must work for AGENT (agt_) callers, not just
# humans. resolve-deploy-org.sh turns a GET /membership/me body into the deploy
# org decision, and the /deploy skill (SKILL.md A.5) must call the agent-aware
# /membership/me endpoint — NOT the old person-only /entity/by-type/person +
# /membership/person chain, which returned nothing for an agent and silently
# downgraded agent deploys to personal scope (feedback_1e8d78ed / DEV-1843: Nanit).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
SRC="$ROOT/.claude/skills/deploy/scripts/resolve-deploy-org.sh"
SKILL="$ROOT/.claude/skills/deploy/SKILL.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$SRC" ] || fail "resolve-deploy-org.sh not found at $SRC"
[ -f "$SKILL" ] || fail "deploy SKILL.md not found at $SKILL"

# Eval the script output in a subshell and echo one requested var back.
run() { # <json> <var>
  ( eval "$(printf '%s' "$1" | bash "$SRC")"; eval "printf '%s' \"\$$2\"" )
}

echo "[1] AGENT single active membership (companySlug enriched) → resolves ORG_SLUG"
J='{"memberships":[{"companyUid":"cmp_nanit","companySlug":"nanit","role":"member","status":"active"}]}'
[ "$(run "$J" ORG_SLUG)" = "nanit" ] || fail "agent single active did not resolve ORG_SLUG=nanit"
[ -z "$(run "$J" PERSONAL_SCOPE)" ] || fail "agent single active wrongly set PERSONAL_SCOPE"
pass "agent single active → ORG_SLUG=nanit, not personal"

echo "[2] human single active membership → resolves ORG_SLUG (no regression)"
J='{"memberships":[{"companyUid":"cmp_acme","companySlug":"acme","role":"owner","status":"active"}]}'
[ "$(run "$J" ORG_SLUG)" = "acme" ] || fail "human single active did not resolve ORG_SLUG=acme"
pass "human single active → ORG_SLUG=acme"

echo "[3] no active membership → personal scope"
J='{"memberships":[{"companyUid":"cmp_x","companySlug":"x","status":"invited"}]}'
[ "$(run "$J" PERSONAL_SCOPE)" = "true" ] || fail "no-active did not set PERSONAL_SCOPE=true"
[ "$(run "$J" ORG_RESOLUTION_STATE)" = "no-orgs" ] || fail "no-active state should be no-orgs"
[ -z "$(run "$J" ORG_SLUG)" ] || fail "no-active wrongly resolved an ORG_SLUG"
pass "no active membership → personal / no-orgs"

echo "[4] multi active membership → multi-org CTA with slug list"
J='{"memberships":[{"companyUid":"c1","companySlug":"alpha","status":"active"},{"companyUid":"c2","companySlug":"beta","status":"active"}]}'
[ "$(run "$J" ORG_RESOLUTION_STATE)" = "multi-org" ] || fail "multi did not set multi-org state"
[ "$(run "$J" ACTIVE_SLUGS)" = "alpha, beta" ] || fail "multi ACTIVE_SLUGS wrong: $(run "$J" ACTIVE_SLUGS)"
[ -z "$(run "$J" ORG_SLUG)" ] || fail "multi wrongly auto-picked an ORG_SLUG"
pass "multi active → multi-org, slugs listed"

echo "[5] single active but companySlug NOT enriched → expose companyUid for entity fallback"
J='{"memberships":[{"companyUid":"cmp_z","status":"active"}]}'
[ -z "$(run "$J" ORG_SLUG)" ] || fail "unenriched single should leave ORG_SLUG empty for fallback"
[ "$(run "$J" ACTIVE_COMPANY_UID)" = "cmp_z" ] || fail "unenriched single should expose ACTIVE_COMPANY_UID=cmp_z"
pass "unenriched single → companyUid exposed for fallback"

echo "[6] empty / malformed body → safe personal default, no crash"
[ "$(run '{}' PERSONAL_SCOPE)" = "true" ] || fail "empty body should default to personal"
[ "$(printf '' | bash "$SRC" | grep -c "=")" -ge 1 ] || fail "empty stdin should still emit KEY=VALUE lines"
pass "empty/malformed → safe personal default"

echo "[7] source-contract: /deploy A.5 uses the AGENT-AWARE /membership/me + resolver"
grep -qF '/membership/me' "$SKILL" || fail "SKILL A.5 does not call the agent-aware /membership/me endpoint"
grep -qF 'resolve-deploy-org.sh' "$SKILL" || fail "SKILL A.5 does not invoke resolve-deploy-org.sh"
pass "A.5 resolves via /membership/me + resolve-deploy-org.sh"

echo "[8] missing jq -> unresolved dependency, NEVER personal scope"
NO_JQ_BIN="$(mktemp -d "${TMPDIR:-/tmp}/resolve-org-no-jq.XXXXXX")"
trap 'rm -rf "$NO_JQ_BIN"' EXIT
OUT=$(PATH="$NO_JQ_BIN" /bin/bash "$SRC" <<<'{"memberships":[{"companySlug":"acme","status":"active"}]}' 2>/dev/null)
eval "$OUT"
[ "$ORG_RESOLUTION_STATE" = "missing_dependency" ] \
  || fail "missing jq should set missing_dependency (got: $ORG_RESOLUTION_STATE)"
[ -z "$PERSONAL_SCOPE" ] \
  || fail "missing jq must not set PERSONAL_SCOPE=true"
[ -z "$ORG_SLUG" ] || fail "missing jq must not guess an org"
grep -q 'missing_dependency)' "$SKILL" \
  || fail "SKILL C.5 must handle missing_dependency explicitly"
pass "missing jq -> missing_dependency; personal scope remains unset"

echo "ALL PASS: resolve-deploy-org"
