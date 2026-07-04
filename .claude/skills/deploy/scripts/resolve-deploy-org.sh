#!/usr/bin/env bash
# resolve-deploy-org.sh — decide the deploy org context from a /membership/me
# response, for BOTH human (prs_) and agent (agt_) callers.
#
# WHY THIS EXISTS: the /deploy org-resolution used to walk a PERSON-only path
# (GET /entity/by-type/person -> GET /membership/person/{personUid}). An AGENT
# machine identity (custom:entityType=agent) has NO person entity — its
# membership rides the agt_ uid — so that path returned nothing and the deploy
# silently downgraded to personal scope, blocking company-scoped deploys for
# agents (feedback_1e8d78ed / DEV-1837: Nanit dashboard). The caller now feeds
# this script the body of GET /membership/me, which the vault service already
# resolves for persons AND agents (it passes agentEntityUid via
# extractAgentIdentity), so agent memberships are included.
#
# INPUT  (stdin): the JSON body of GET /membership/me, i.e. { "memberships": [
#          { "companyUid", "companySlug"?, "role", "status", ... }, ... ] }.
# OUTPUT (stdout): shell KEY=VALUE lines for the caller to eval —
#          ORG_SLUG=<slug|empty>            single active membership resolved
#          ORG_RESOLUTION_STATE=<""|no-orgs|multi-org>
#          PERSONAL_SCOPE=<""|true>         no active membership -> personal scope
#          ACTIVE_SLUGS=<comma-joined>      only set for multi-org (CTA list)
#          ACTIVE_COMPANY_UID=<uid|empty>   single-membership companyUid (slug fallback)
# nounset-safe; always exits 0. Never trusts anything but stdin (pure function).
set -euo pipefail

IN="$(cat 2>/dev/null || true)"

ORG_SLUG=""
ORG_RESOLUTION_STATE=""
PERSONAL_SCOPE=""
ACTIVE_SLUGS=""
ACTIVE_COMPANY_UID=""

# Active memberships only. `// []` guards a missing/empty memberships array.
ACTIVE="$(printf '%s' "$IN" | jq -c '[(.memberships // [])[] | select(.status=="active")]' 2>/dev/null || echo '[]')"
[ -n "$ACTIVE" ] || ACTIVE='[]'
COUNT="$(printf '%s' "$ACTIVE" | jq 'length' 2>/dev/null || echo 0)"

case "$COUNT" in
  1)
    ORG_SLUG="$(printf '%s' "$ACTIVE" | jq -r '.[0].companySlug // empty' 2>/dev/null || true)"
    ACTIVE_COMPANY_UID="$(printf '%s' "$ACTIVE" | jq -r '.[0].companyUid // empty' 2>/dev/null || true)"
    ;;
  0)
    ORG_RESOLUTION_STATE="no-orgs"
    PERSONAL_SCOPE="true"
    ;;
  *)
    ORG_RESOLUTION_STATE="multi-org"
    ACTIVE_SLUGS="$(printf '%s' "$ACTIVE" | jq -r '[.[].companySlug // empty | select(. != "")] | join(", ")' 2>/dev/null || true)"
    ;;
esac

# Single-quote every value so the caller can eval this safely. Company slugs
# and company uids are a constrained charset (server-validated) and never
# contain a single quote, so plain single-quoting is sufficient and injection-safe.
printf "ORG_SLUG='%s'\n" "$ORG_SLUG"
printf "ORG_RESOLUTION_STATE='%s'\n" "$ORG_RESOLUTION_STATE"
printf "PERSONAL_SCOPE='%s'\n" "$PERSONAL_SCOPE"
printf "ACTIVE_SLUGS='%s'\n" "$ACTIVE_SLUGS"
printf "ACTIVE_COMPANY_UID='%s'\n" "$ACTIVE_COMPANY_UID"
