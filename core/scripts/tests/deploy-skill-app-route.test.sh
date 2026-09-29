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

printf '%s\n' "$APP_UPLOAD_CODE" | grep -Fq 'if [ "$DEPLOY_TYPE" = "app" ]; then' \
  || fail "app upload is not selected from DEPLOY_TYPE"
printf '%s\n' "$APP_UPLOAD_CODE" | grep -Fq -- '--url "$API/api/apps/$APP_ID/deploy"' \
  || fail "app upload does not use the type=app route"
printf '%s\n' "$APP_UPLOAD_CODE" | grep -Fq -- "--form-string 'type=app'" \
  || fail "app upload does not submit type=app as a multipart field"
printf '%s\n' "$APP_UPLOAD_CODE" | grep -Fq -- '--form-file "file=$TARBALL_PATH"' \
  || fail "app upload does not send the tarball as a multipart file"
printf '%s\n' "$APP_UPLOAD_CODE" | grep -Fq '.statusUrl' \
  || fail "app upload does not validate the app route response shape"
printf '%s\n' "$APP_UPLOAD_CODE" | grep -Fq 'LIVE_URL="https://${APP_SUBDOMAIN}.${HQ_DEPLOY_DOMAIN:-indigo-hq.com}"' \
  || fail "app upload does not derive the public URL from the app subdomain"
if printf '%s\n' "$APP_UPLOAD_CODE" | grep -Eq '/api/deploys|deploy-completion|presignedUrl'; then
  fail "app upload still uses the static presigned deploy flow"
fi
printf '%s\n' "$STATIC_SECTION" | grep -Fq -- '--url "$API/api/deploys"' \
  || fail "static uploads no longer use the presigned deploy route"
printf '%s\n' "$STATIC_SECTION" | grep -Fq 's3-upload --no-auth --method PUT' \
  || fail "static uploads no longer PUT the presigned artifact"
grep -Fq 'guardrails-check.sh "$OUTPUT_DIR" "$GUARDRAILS_API_DIR"' "$SKILL" \
  || fail "Phase B does not include root api/ handlers in the app artifact"

pass 'app deploy uses the app handler route while static deploy remains presigned'
