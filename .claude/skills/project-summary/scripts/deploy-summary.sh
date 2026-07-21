#!/usr/bin/env bash
# deploy-summary.sh — deploy a visual project summary to hq-deploy.
#
# Generalized from companies/indigo/skills/standup-brief/deploy-brief.sh:
#   - reuses the shared deploy scripts (identity-resolve, guardrails-check)
#   - idempotent: reuses a fixed app name so the URL is stable across reruns
#   - company-gated when a company slug + cloud_uid resolve from companies/manifest.yaml
#   - password-protected fallback for personal / no-company projects
#
# Usage: bash deploy-summary.sh <build-dir> <app-name> [company-slug]
#   <build-dir>     directory containing index.html (the artifact root)
#   <app-name>      stable app name, e.g. "indigo-installer-import-step-summary"
#   [company-slug]  optional; when set + resolvable, gate to that company's members
#
# Prints (stdout, KEY=VALUE lines) on success:
#   LIVE=<url>
#   MODE=company|password
#   GATE=<http_code>          # 302 when a gate is active
#   PASSWORD=<pw>             # only when MODE=password
# Exits non-zero with "ERR: <reason>" on stderr+stdout when it cannot deploy.
# The caller treats any failure as NON-FATAL (PRD creation must not be blocked).
set -euo pipefail

BUILD_DIR="${1:?usage: deploy-summary.sh <build-dir> <app-name> [company-slug]}"
APP_NAME="${2:?usage: deploy-summary.sh <build-dir> <app-name> [company-slug]}"
CO_SLUG="${3:-}"

# Resolve HQ root from this script's location: .claude/skills/project-summary/scripts/ -> 4 up.
HQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DEPLOY="$HQ_ROOT/.claude/skills/deploy/scripts"

fail() { echo "ERR: $1"; exit 1; }

cd "$HQ_ROOT"

# Resolve the hq-deploy API base with the same chain + public default as the
# canonical resolver .claude/skills/deploy/scripts/resolve-deploy-api.sh:
#   $HQ_DEPLOY_API -> manifest services.hq-deploy.endpoint -> https://api.indigo-hq.com.
# Kept inline here (rather than calling the resolver) so this script stays
# self-contained, but the public default is intentionally identical so the two
# stay reconciled. Never hardcode a tenant-specific host inline.
# HQ_DEPLOY_API is an OPTIONAL override — default it to empty so an unset var
# under `set -u` (nounset) doesn't abort here; the manifest + public-default
# fallback below then resolves the base (feedback_3cdd3064).
API="${HQ_DEPLOY_API:-}"
if [ -z "$API" ] && [ -f companies/manifest.yaml ]; then
  API="$(awk -F'endpoint:[ \t]*' '/hq-deploy/{f=1} f&&/endpoint:/{gsub(/[ \t\r]+$/,"",$2); print $2; exit}' companies/manifest.yaml 2>/dev/null)"
fi
API="${API:-https://api.indigo-hq.com}"
[ -d "$BUILD_DIR" ] || fail "build_dir_missing:$BUILD_DIR"
[ -f "$BUILD_DIR/index.html" ] || fail "no_index_html:$BUILD_DIR"

# 1. Identity (JWT) + HQ Pro token for policy-gated access-policy calls.
JWT="$("$DEPLOY/identity-resolve.sh" 2>/dev/null | jq -r '.jwt // empty')"
[ -n "$JWT" ] || fail "no_identity (run /hq-login)"
HQ_PRO_JWT="$(jq -r '.idToken // .accessToken // empty' "${HOME:-}/.hq/cognito-tokens.json" 2>/dev/null || true)"

# 2. Guardrails + tarball.
GR="$("$DEPLOY/guardrails-check.sh" "$BUILD_DIR" 2>/dev/null)"
[ "$(echo "$GR" | jq -r '.pass')" = "true" ] || fail "guardrails:$(echo "$GR" | jq -r '.reason')"
TB="$(echo "$GR" | jq -r '.tarball_path')"
SZ="$(echo "$GR" | jq -r '.size_bytes')"
SHA="$(echo "$GR" | jq -r '.sha256')"

# 3. Resolve company cloud_uid from the manifest (indented `<slug>:` block).
CO_UID=""
if [ -n "$CO_SLUG" ] && [ -f companies/manifest.yaml ]; then
  CO_UID="$(awk -v want="  $CO_SLUG:" '
    $0==want {found=1; next}
    found && /^  [a-z0-9_-]+:/ {exit}
    found && /cloud_uid:/ {gsub(/.*cloud_uid:[ \t]*/,""); gsub(/[ \t\r]+$/,""); print; exit}
  ' companies/manifest.yaml)"
fi

# 4. Create or reuse the app (idempotent -> stable subdomain).
SUB="$(curl -s -H "Authorization: Bearer $JWT" "$API/api/apps" \
  | jq -r --arg n "$APP_NAME" '.apps[]?|select(.name==$n)|.subdomain' | head -1)"
if [ -z "$SUB" ] || [ "$SUB" = "null" ]; then
  R="$(curl -s -X POST -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
        -d "{\"name\":\"$APP_NAME\",\"type\":\"static\"}" "$API/api/apps")"
  SUB="$(echo "$R" | jq -r '.subdomain')"
fi
[ -n "$SUB" ] && [ "$SUB" != "null" ] || fail "app_create_failed"

# 5. Upload via presigned S3 URL, then complete.
D="$(curl -s -X POST -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
      -d "{\"appSlug\":\"$SUB\",\"manifest\":{\"files\":[],\"size\":$SZ,\"sha256\":\"$SHA\"}}" \
      "$API/api/deploys")"
DID="$(echo "$D" | jq -r '.deployId')"
PRES="$(echo "$D" | jq -r '.presignedUrl')"
[ -n "$PRES" ] && [ "$PRES" != "null" ] || { rm -f "$TB"; fail "deploy_init_failed"; }
curl -s -X PUT -H "Content-Type: application/gzip" --data-binary @"$TB" "$PRES" -o /dev/null
LIVE="$(curl -s -X POST -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
        -d "{\"appSlug\":\"$SUB\"}" "$API/api/deploys/$DID/complete" | jq -r '.url')"
rm -f "$TB"
[ -n "$LIVE" ] && [ "$LIVE" != "null" ] || fail "deploy_complete_failed"

# 6. Wire access mode.
APP_ID="$(curl -s -H "Authorization: Bearer $JWT" "$API/api/apps" \
  | jq -r --arg n "$APP_NAME" '.apps[]?|select(.name==$n)|.id' | head -1)"
[ -n "$APP_ID" ] && [ "$APP_ID" != "null" ] || fail "app_id_unresolved"

is_2xx() { [[ "$1" =~ ^2[0-9]{2}$ ]]; }

read_app_state() {
  local response status
  response="$(curl -sS -w $'\n%{http_code}' -H "Authorization: Bearer $JWT" \
    "$API/api/apps/$APP_ID" || true)"
  status="${response##*$'\n'}"
  is_2xx "$status" || return 1
  APP_STATE="${response%$'\n'*}"
}

# The company policy lives behind its OWN endpoint. `GET /api/apps/{id}`
# reports accessMode but returns accessPolicy: null for every app, gated or
# not — so reading .accessPolicy.companyUid from it ALWAYS yields empty.
# Verifying a company gate against that field could therefore never succeed,
# and the "unverified" branch below overwrote the correct company gate with a
# password gate on every single company deploy. A verification that cannot
# pass is worse than no verification: it actively destroyed the thing it was
# checking. Caught by a live smoke on 2026-07-19; no unit test saw it because
# the API shape was mocked.
read_access_policy() {
  local response status
  response="$(curl -sS -w $'\n%{http_code}' -H "Authorization: Bearer $JWT" \
    "$API/api/apps/$APP_ID/access-policy" || true)"
  status="${response##*$'\n'}"
  is_2xx "$status" || return 1
  POLICY_STATE="${response%$'\n'*}"
}

verify_gate() {
  local expected_mode="$1" expected_uid="${2:-}" attempt state_mode protected policy_mode policy_uid
  for attempt in 1 2 3; do
    if read_app_state; then
      state_mode="$(printf '%s' "$APP_STATE" | jq -r '.accessMode // empty')"
      protected="$(printf '%s' "$APP_STATE" | jq -r '.passwordProtected // false')"
      GATE="$(curl -sS -o /dev/null -w '%{http_code}' "$LIVE/" || true)"
      if [ "$GATE" = "302" ] && [ "$state_mode" = "$expected_mode" ]; then
        if [ "$expected_mode" = "password" ] && [ "$protected" = "true" ]; then
          return 0
        fi
        if [ "$expected_mode" = "company" ] && read_access_policy; then
          policy_mode="$(printf '%s' "$POLICY_STATE" | jq -r '.mode // empty')"
          policy_uid="$(printf '%s' "$POLICY_STATE" | jq -r '.companyUid // empty')"
          # Full proof: edge redirects, app record says company, AND the policy
          # record binds the company we asked for.
          if [ "$policy_mode" = "company" ] && [ "$policy_uid" = "$expected_uid" ]; then
            return 0
          fi
        fi
      fi
    fi
    [ "$attempt" -lt 3 ] && sleep 1
  done
  return 1
}

set_company_gate() {
  local status
  status="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$API/api/apps/$APP_ID/access-policy" \
    -H "Authorization: Bearer $JWT" \
    ${HQ_PRO_JWT:+-H "X-HQ-Pro-Authorization: Bearer $HQ_PRO_JWT"} \
    -H "Content-Type: application/json" \
    -d "{\"mode\":\"company\",\"companyUid\":\"$CO_UID\",\"users\":[],\"groups\":[]}" || true)"
  is_2xx "$status"
}

set_password_gate() {
  local status
  status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API/api/apps/$APP_ID/access-mode" \
    -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
    -d "{\"mode\":\"password\",\"password\":\"$PW\"}" || true)"
  is_2xx "$status"
}

if [ -n "$CO_UID" ]; then
  # Company-gated: restrict to active members of the project's company.
  if set_company_gate && verify_gate company "$CO_UID"; then
    echo "LIVE=$LIVE"
    echo "MODE=company"
    echo "GATE=$GATE"   # 302 -> members-only sign-in
    exit 0
  fi
  echo "ERR: company_gate_unverified; trying password fallback" >&2
fi

# Password fallback (personal / no resolvable company, or unproven company gate).
PW="$("$DEPLOY/password-helper.sh" gen)"
if set_password_gate && verify_gate password; then
  "$DEPLOY/password-helper.sh" announce "$SUB" "$PW" project-summary >/dev/null 2>&1 || true
  echo "LIVE=$LIVE"
  echo "MODE=password"
  echo "GATE=$GATE"
  echo "PASSWORD=$PW"
  exit 0
fi

fail "access_gate_unverified"
