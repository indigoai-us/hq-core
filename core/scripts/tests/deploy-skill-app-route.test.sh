#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/deploy/SKILL.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$SKILL" ] || fail "deploy skill is missing: $SKILL"
APP_UPLOAD_CODE="$(awk '
  /^#### App upload/ { in_app = 1 }
  in_app && /^```bash$/ { in_code = 1; next }
  in_code && /^```$/ { exit }
  in_code { print }
' "$SKILL")"
STATIC_SECTION="$(awk '
  /^#### Static upload/ { in_static = 1 }
  /^#### App upload/ { in_static = 0 }
  in_static { print }
' "$SKILL")"

printf '%s\n' "$APP_UPLOAD_CODE" | grep >/dev/null -F 'if [ "$DEPLOY_TYPE" = "app" ]; then' \
  || fail "app upload is not selected from DEPLOY_TYPE"
# hq deploy upload-app sends the multipart type=app deploy to the app route
# (POST /api/apps/:id/deploy) and checks the receipt itself.
printf '%s\n' "$APP_UPLOAD_CODE" | grep >/dev/null -F -- 'hq_deploy upload-app "$APP_ID" "$TARBALL_PATH" "${HQ_SCOPE_ARGS[@]}"' \
  || fail "app upload does not use hq deploy upload-app with the tarball and scope"
printf '%s\n' "$APP_UPLOAD_CODE" | grep >/dev/null -F '.statusUrl' \
  || fail "app upload does not check the receipt shape"
printf '%s\n' "$APP_UPLOAD_CODE" | grep >/dev/null -F 'LIVE_URL="${APP_URL:-https://${APP_SUBDOMAIN}.${HQ_DEPLOY_DOMAIN:-indigo-hq.com}}"' \
  || fail "app upload does not use the API-returned app URL"

# The printed link is the URL the API returns. Until the platform switch the API
# returns indigo-hq.com, so the skill must never build a link on hq.work itself.
FIND_APP_CODE="$(awk '
  /^#### Find or create the app/ { in_find = 1 }
  in_find && /^```bash$/ { in_code = 1; next }
  in_code && /^```$/ { exit }
  in_code { print }
' "$SKILL")"
[ -n "$FIND_APP_CODE" ] || fail "could not extract the Find or create the app block"

# find_app_url <apps_json> <create_response> <reread_response> [HQ_DEPLOY_DOMAIN]
# Runs the real block with a stub hq_deploy (create, app-info); prints APP_URL.
find_app_url() {
  APPS_JSON="$1" CREATE_RESPONSE="$2" REREAD_RESPONSE="$3" HQ_DEPLOY_DOMAIN="${4:-}" \
    FIND_APP_CODE="$FIND_APP_CODE" bash -c '
    set -euo pipefail
    [ -n "$HQ_DEPLOY_DOMAIN" ] || unset HQ_DEPLOY_DOMAIN
    hq_deploy() {
      case "$1" in
        create) printf "%s" "$CREATE_RESPONSE" ;;
        app-info) [ -n "$REREAD_RESPONSE" ] || return 1; printf "%s" "$REREAD_RESPONSE" ;;
        *) echo "unexpected hq deploy $1" >&2; return 1 ;;
      esac
    }
    HQ_SCOPE_ARGS=(--company acme)
    deploy_request() { echo "unexpected deploy_request $1" >&2; return 1; }
    ROUTE_MODE=false APP_NAME=report DEPLOY_TYPE=static API=https://api.hq.work
    eval "$FIND_APP_CODE"
    printf "%s\n" "$APP_URL"'
}
expect_url() {  # expect_url <label> <expected> <got>
  [ "$3" = "$2" ] && pass "$1 -> $3" || fail "$1: expected $2, got '$3'"
}
OTHER_OLD='{"name":"other","id":"o1","subdomain":"other","url":"https://other.indigo-hq.com"}'
OTHER_NEW='{"name":"other","id":"o1","subdomain":"other","url":"https://other.hq.work"}'
expect_url "existing app: list url, as returned" "https://report.indigo-hq.com" \
  "$(find_app_url '{"apps":[{"name":"report","id":"a1","subdomain":"report","url":"https://report.indigo-hq.com/"}]}' '' '')"
expect_url "existing app on a company domain" "https://report.acme.example" \
  "$(find_app_url '{"apps":[{"name":"report","id":"a1","subdomain":"report","url":"https://report.acme.example"}]}' '' '')"
expect_url "new app: create response url" "https://report.indigo-hq.com" \
  "$(find_app_url '{"apps":[]}' '{"id":"a2","subdomain":"report","url":"https://report.indigo-hq.com"}' '')"
expect_url "after the platform switch the API's hq.work url is printed" "https://report.hq.work" \
  "$(find_app_url '{"apps":[]}' '{"id":"a2","subdomain":"report","url":"https://report.hq.work"}' '')"
expect_url "no url on create: re-read from the API" "https://report.indigo-hq.com" \
  "$(find_app_url '{"apps":[]}' '{"id":"a2","subdomain":"report"}' '{"id":"a2","url":"https://report.indigo-hq.com"}')"
expect_url "no url anywhere: domain of the org's other apps (before the switch)" "https://report.indigo-hq.com" \
  "$(find_app_url "{\"apps\":[$OTHER_OLD]}" '{"id":"a2","subdomain":"report"}' '{"id":"a2"}')"
expect_url "no url anywhere: domain of the org's other apps (after the switch)" "https://report.hq.work" \
  "$(find_app_url "{\"apps\":[$OTHER_NEW]}" '{"id":"a2","subdomain":"report"}' '{"id":"a2"}')"
expect_url "no url anywhere and no other apps: indigo-hq.com, never a built hq.work" "https://report.indigo-hq.com" \
  "$(find_app_url '{"apps":[]}' '{"id":"a2","subdomain":"report"}' '')"
expect_url "HQ_DEPLOY_DOMAIN override applies only to the last resort" "https://report.example.test" \
  "$(find_app_url "{\"apps\":[$OTHER_OLD]}" '{"id":"a2","subdomain":"report"}' '' example.test)"
expect_url "HQ_DEPLOY_DOMAIN never replaces a url the API returned" "https://report.indigo-hq.com" \
  "$(find_app_url '{"apps":[]}' '{"id":"a2","subdomain":"report","url":"https://report.indigo-hq.com"}' '' example.test)"

grep -Fq 'og-inject.sh "$OUTPUT_DIR" "$BASE_URL" "$APP_NAME" "$API"' "$SKILL" \
  || fail "og-inject does not get the deploy API base for the card"
grep -Fq 'BASE_URL="${APP_URL:-' "$SKILL" || fail "preview-tag base URL is not the API-returned app URL"
grep -Fq -- '--url "$LIVE_URL"' "$SKILL" || fail "route-host record does not store the API-returned live URL"
if grep -Eq 'HQ_DEPLOY_DOMAIN:-hq\.work|https://(\{app\}|\{sub\}|<host>|\$APP_SUBDOMAIN|\$\{APP_SUBDOMAIN\})\.(hq\.work|indigo-hq\.com)/?(<route>/)?"' "$SKILL"; then
  fail "a link is built on a hardcoded domain instead of the URL the API returned"
fi
for f in "$SKILL" "$ROOT/core/policies/auto-deploy-on-create.md"; do
  if grep -Eq "(link you can share|live at)[^\"]*https://\{app\}\." "$f"; then
    fail "a link template in $f hardcodes a domain"
  fi
done
grep -Fq 'Here'"'"'s a link you can share: $LIVE_URL' "$SKILL" || fail "share template does not print \$LIVE_URL"
grep -Fq 'onboarding.indigo-hq.com' "$SKILL" && fail "dead onboarding.indigo-hq.com sign-up link is back"
grep -Fq 'indigo-hq.com links keep working' "$SKILL" || fail "missing the note that old links keep working"
if printf '%s\n' "$APP_UPLOAD_CODE" | grep >/dev/null -E '/api/deploys|deploy-completion|presignedUrl'; then
  fail "app upload still uses the static presigned deploy flow"
fi
grep -Fq 'hq_deploy upload "$APP_SUBDOMAIN" "$TARBALL_PATH" "${HQ_SCOPE_ARGS[@]}" --manifest-org --json' <<<"$STATIC_SECTION" \
  || fail "static uploads do not use hq deploy upload (the presigned deploy flow)"
if grep -Eq 'deploy_request (deploy-creation|s3-upload|deploy-completion)' <<<"$STATIC_SECTION"; then
  fail "static uploads still call the presigned deploy routes directly"
fi
grep -Fq 'guardrails-check.sh "$OUTPUT_DIR" "$GUARDRAILS_API_DIR"' "$SKILL" \
  || fail "Phase B does not include root api/ handlers in the app artifact"

pass 'app deploy uses the app handler route while static deploy remains presigned'
