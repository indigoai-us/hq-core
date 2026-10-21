#!/usr/bin/env bash
# deploy-summary.sh — deploy a visual project summary to hq-deploy.
#
# Generalized from companies/indigo/skills/standup-brief/deploy-brief.sh:
#   - reuses the shared deploy scripts (identity-resolve, guardrails-check, list-apps)
#   - idempotent: reuses a fixed app name so the URL is stable across reruns
#   - company-gated when a company slug + cloud_uid resolve from companies/manifest.yaml
#   - password-protected fallback for personal / no-company projects
#   - gate first: the access gate is applied and proven BEFORE content is
#     uploaded, and the app is taken down if the gate cannot be proven on the
#     live URL afterwards. No path leaves new content public.
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

is_2xx() { [[ "$1" =~ ^2[0-9]{2}$ ]]; }

# Gate proof polls the API and the anonymous edge. The edge caches each app's
# registry row for up to 60s, so the default budget covers that window.
GATE_ATTEMPTS="${HQ_DEPLOY_GATE_ATTEMPTS:-12}"
GATE_SLEEP="${HQ_DEPLOY_GATE_SLEEP_SECS:-5}"

# 4. Find or create the app (idempotent -> stable subdomain).
# GET /api/apps is paginated (nextCursor), so list-apps.sh reads every page.
# Reading only page one missed existing apps once the org passed one page of
# apps, and a new app lands on a random page. On 2026-10-18 the old
# post-upload lookup here missed twice, after the content was already live,
# and the script exited before gating: two internal pages were public for
# minutes. The id now comes from the lookup or from the create response, and
# the gate is applied and proven BEFORE any content is uploaded.
APP_JSON="$(HQ_DEPLOY_JWT="$JWT" "$DEPLOY/list-apps.sh" --api "$API" --name "$APP_NAME")" \
  || fail "app_list_failed"
APP_EXISTED=false
if [ -n "$APP_JSON" ]; then
  APP_EXISTED=true
else
  R="$(curl -sS -w $'\n%{http_code}' -X POST -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
        -d "{\"name\":\"$APP_NAME\",\"type\":\"static\"}" "$API/api/apps" || true)"
  is_2xx "${R##*$'\n'}" || fail "app_create_failed"
  APP_JSON="${R%$'\n'*}"
fi
APP_ID="$(printf '%s' "$APP_JSON" | jq -r '.id // empty' 2>/dev/null || true)"
SUB="$(printf '%s' "$APP_JSON" | jq -r '.subdomain // empty' 2>/dev/null || true)"
APP_URL="$(printf '%s' "$APP_JSON" | jq -r '.url // empty' 2>/dev/null || true)"
[ -n "$APP_ID" ] || fail "app_id_unresolved"
[ -n "$SUB" ] || fail "app_create_failed"

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

# API-side proof: the app record (and, for company, the policy record) says
# the requested gate is in force.
gate_state_ok() {
  local expected_mode="$1" expected_uid="${2:-}" state_mode protected policy_mode policy_uid
  read_app_state || return 1
  state_mode="$(printf '%s' "$APP_STATE" | jq -r '.accessMode // empty')"
  protected="$(printf '%s' "$APP_STATE" | jq -r '.passwordProtected // false')"
  [ "$state_mode" = "$expected_mode" ] || return 1
  if [ "$expected_mode" = "password" ]; then
    [ "$protected" = "true" ]
    return
  fi
  # Full proof for company: the policy record binds the company we asked for.
  read_access_policy || return 1
  policy_mode="$(printf '%s' "$POLICY_STATE" | jq -r '.mode // empty')"
  policy_uid="$(printf '%s' "$POLICY_STATE" | jq -r '.companyUid // empty')"
  [ "$policy_mode" = "company" ] && [ "$policy_uid" = "$expected_uid" ]
}

# Edge-side proof: an anonymous request is redirected to sign-in.
edge_gated() {
  GATE="$(curl -sS -o /dev/null -w '%{http_code}' "$1/" || true)"
  [ "$GATE" = "302" ]
}

# verify_gate <mode> <uid> [url]: poll until the API state matches and, when a
# url is given, the anonymous edge answers 302.
verify_gate() {
  local expected_mode="$1" expected_uid="${2:-}" url="${3:-}" attempt
  for attempt in $(seq 1 "$GATE_ATTEMPTS"); do
    if gate_state_ok "$expected_mode" "$expected_uid" \
      && { [ -z "$url" ] || edge_gated "$url"; }; then
      return 0
    fi
    [ "$attempt" -lt "$GATE_ATTEMPTS" ] && sleep "$GATE_SLEEP"
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

# Soft-delete (PATCH active:false). The edge stops serving an inactive app and
# the API pulls its DNS record; the app can be re-activated from the console.
take_down() {
  local status
  status="$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$API/api/apps/$APP_ID" \
    -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
    -d '{"active":false}' || true)"
  is_2xx "$status"
}

# 5. Apply and prove the gate BEFORE uploading. If no gate can be proven,
# nothing is uploaded.
MODE=""
PW=""
GATE=""
if [ -n "$CO_UID" ]; then
  # Company-gated: restrict to active members of the project's company.
  if set_company_gate && verify_gate company "$CO_UID"; then
    MODE=company
  else
    echo "ERR: company_gate_unverified; trying password fallback" >&2
  fi
fi
if [ -z "$MODE" ]; then
  # Password fallback (personal / no resolvable company, or unproven company gate).
  PW="$("$DEPLOY/password-helper.sh" gen)"
  if set_password_gate && verify_gate password; then
    MODE=password
  else
    rm -f "$TB"
    fail "access_gate_unverified (nothing uploaded)"
  fi
fi
# An existing app may already be serving content, and the edge caches its old
# access state for up to 60s. Wait until the anonymous edge redirects before
# new content goes up.
if [ "$APP_EXISTED" = true ] && [ -n "$APP_URL" ]; then
  if ! verify_gate "$MODE" "$CO_UID" "$APP_URL"; then
    rm -f "$TB"
    fail "access_gate_not_at_edge (nothing uploaded)"
  fi
fi

# 6. Upload via presigned S3 URL, then complete.
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
# A complete call that went live without returning a url is still behind the
# gate applied in step 5.
[ -n "$LIVE" ] && [ "$LIVE" != "null" ] || fail "deploy_complete_failed"

# 7. Prove the gate on the live URL. If it cannot be proven, take the app
# down instead of leaving it reachable.
if ! verify_gate "$MODE" "$CO_UID" "$LIVE"; then
  if take_down; then
    fail "access_gate_unverified_after_upload; app taken down (inactive): $LIVE"
  fi
  fail "access_gate_unverified_after_upload; TAKEDOWN FAILED, $LIVE may be PUBLIC (last edge status ${GATE:-unknown}). Deactivate it in the HQ console now."
fi

echo "LIVE=$LIVE"
echo "MODE=$MODE"
echo "GATE=$GATE"   # 302 -> members-only sign-in or password prompt
if [ "$MODE" = "password" ]; then
  "$DEPLOY/password-helper.sh" announce "$SUB" "$PW" project-summary >/dev/null 2>&1 || true
  echo "PASSWORD=$PW"
fi
exit 0
