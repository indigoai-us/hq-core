#!/usr/bin/env bash
# Regression: deploy requests must retain HTTP error context and stop Phase C
# before a later app/deploy/upload/complete call can run.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SRC="$ROOT/.claude/skills/deploy/scripts/deploy-api-request.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -x "$SRC" ] || fail "deploy-api-request.sh is missing or not executable"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TOKEN='token-secret-should-not-leak'
SIGNATURE='presigned-secret-should-not-leak'

mkdir -p "$TMP/bin"
printf 'artifact\n' > "$TMP/archive.tar.gz"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

body_file=""
url=""
method=GET
authorization=""
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  case "$arg" in
    -o) next=$((i + 1)); body_file="${!next}" ;;
    -X) next=$((i + 1)); method="${!next}" ;;
    -H)
      next=$((i + 1))
      case "${!next}" in Authorization:*) authorization="${!next}" ;; esac
      ;;
    http://*|https://*) url="$arg" ;;
  esac
done

printf '%s %s\n' "$method" "$url" >> "$MOCK_DIR/calls"
stage=""
case "$url" in
  http://api.test/api/apps)
    if [ "$method" = POST ]; then stage=app-creation; body='{"id":"app-1","subdomain":"app"}'
    else stage=app-list; body='{"apps":[]}'
    fi ;;
  http://api.test/api/deploys) stage=deploy-creation; body='{"deployId":"deploy-1","presignedUrl":"https://upload.test/archive?X-Amz-Signature=presigned-secret-should-not-leak&X-Amz-Credential=credential-secret"}' ;;
  https://upload.test/archive\?*) stage=s3-upload; body='' ;;
  http://api.test/api/deploys/deploy-1/complete) stage=deploy-completion; body='{"url":"https://live.test"}' ;;
  *) echo "unexpected curl request: $method $url" >&2; exit 9 ;;
esac

status=200
printf '%s %s\n' "$stage" "$authorization" >> "$MOCK_DIR/auth-calls"
stage_calls="$(grep -c "^$method $url$" "$MOCK_DIR/calls" || true)"
if [ "$stage" = "${REFRESH_STAGE:-}" ] && [ "$stage_calls" = 1 ]; then
  status=401
  body='{"error":{"code":"TOKEN_EXPIRED","message":"Expired token-secret-should-not-leak X-Amz-Signature=presigned-secret-should-not-leak"},"requestId":"req-401"}'
elif [ "$stage" = "${REFRESH_STAGE:-}" ] && [ "${RETRY_STATUS:-200}" != 200 ]; then
  status="$RETRY_STATUS"
  body='{"error":{"code":"RETRY_DENIED","message":"Retry denied refreshed-secret-should-not-leak X-Amz-Signature=presigned-secret-should-not-leak"},"requestId":"req-retry"}'
elif [ "$stage" = "$FAIL_STAGE" ]; then
  status="${FAIL_STATUS:-403}"
  body='{"error":{"code":"FORBIDDEN","message":"Denied token-secret-should-not-leak X-Amz-Signature=presigned-secret-should-not-leak"},"requestId":"req-403"}'
elif [ "$stage" = "${INVALID_STAGE:-}" ]; then
  body='{"unexpected":true}'
fi
printf '%s' "$body" > "$body_file"
printf '%s' "$status"
STUB
chmod +x "$TMP/bin/curl"

cat > "$TMP/identity-resolve" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DIR/identity-calls"
if [ "${REFRESH_RESULT:-ok}" = ok ]; then
  printf '%s\n' '{"status":"ok","jwt":"refreshed-secret-should-not-leak","id_token":"id-secret-should-not-leak","expires_at":9999999999999,"source":"refresh"}'
else
  printf '%s\n' '{"status":"login_required","reason":"refresh failed token-secret-should-not-leak"}'
fi
STUB
chmod +x "$TMP/identity-resolve"

run_phase_c() {
  local request app_response deploy_response presigned_url
  request() {
    HQ_DEPLOY_JWT="$TOKEN" HQ_DEPLOY_IDENTITY_RESOLVER="$TMP/identity-resolve" \
      "$SRC" --org acme --scope company --header 'X-Org-Slug: acme' "$@"
  }

  request --stage app-list --method GET --url http://api.test/api/apps --expect '.apps | type == "array"' >/dev/null || return
  app_response="$(request --stage app-creation --method POST --url http://api.test/api/apps --data '{"name":"app","type":"static"}' --expect '(.id | type == "string" and length > 0)')" || return
  deploy_response="$(request --stage deploy-creation --method POST --url http://api.test/api/deploys --data '{"appSlug":"app"}' --expect '(.deployId | type == "string" and length > 0) and (.presignedUrl | type == "string" and length > 0)')" || return
  presigned_url="$(printf '%s' "$deploy_response" | jq -r '.presignedUrl')"
  request --stage s3-upload --method PUT --url "$presigned_url" --upload-file "$TMP/archive.tar.gz" --no-auth >/dev/null || return
  request --stage deploy-completion --method POST --url http://api.test/api/deploys/deploy-1/complete --data '{"appSlug":"app"}' --expect '(.url | type == "string" and length > 0)' >/dev/null
}

assert_case() {
  local stage="$1" expected_calls="$2" expected_method="$3" expected_url="$4" output code calls
  : > "$TMP/calls"
  : > "$TMP/auth-calls"
  : > "$TMP/identity-calls"
  set +e
  output="$(PATH="$TMP/bin:$PATH" MOCK_DIR="$TMP" FAIL_STAGE="$stage" run_phase_c 2>&1)"
  code=$?
  set -e
  [ "$code" -ne 0 ] || fail "$stage unexpectedly succeeded"
  calls="$(wc -l < "$TMP/calls" | tr -d ' ')"
  [ "$calls" = "$expected_calls" ] || fail "$stage made $calls calls, expected $expected_calls: $output"
  printf '%s' "$output" | grep -Fq "stage=$stage" || fail "$stage diagnostic missing exact stage: $output"
  printf '%s' "$output" | grep -Fq "method=$expected_method" || fail "$stage diagnostic missing method: $output"
  printf '%s' "$output" | grep -Fq "url=$expected_url" || fail "$stage diagnostic missing sanitized URL: $output"
  printf '%s' "$output" | grep -Fq 'status=403' || fail "$stage diagnostic missing status: $output"
  printf '%s' "$output" | grep -Fq 'api_code=FORBIDDEN' || fail "$stage diagnostic missing API code: $output"
  printf '%s' "$output" | grep -Fq 'request_id=req-403' || fail "$stage diagnostic missing request ID: $output"
  printf '%s' "$output" | grep -Fq 'org=acme scope=company authorization=forbidden' || fail "$stage diagnostic missing non-secret scope context: $output"
  printf '%s' "$output" | grep -Fq 'Authorization' && fail "$stage diagnostic leaked an Authorization header: $output"
  printf '%s' "$output" | grep -Fq "$TOKEN" && fail "$stage diagnostic leaked bearer token: $output"
  printf '%s' "$output" | grep -Fq "$SIGNATURE" && fail "$stage diagnostic leaked presigned signature: $output"
  pass "$stage reports 403 context and stops before later calls"
}

echo '[1] 403 at app creation stops before deploy creation'
assert_case app-creation 2 POST http://api.test/api/apps

echo '[2] 403 at deploy creation stops before S3 upload'
assert_case deploy-creation 3 POST http://api.test/api/deploys

echo '[3] 403 at S3 upload strips the presigned query and skips completion'
assert_case s3-upload 4 PUT https://upload.test/archive

echo '[4] 403 at completion retains completion stage context'
assert_case deploy-completion 5 POST http://api.test/api/deploys/deploy-1/complete

echo '[5] failed 401 refresh stops with an explicit live-content outcome'
: > "$TMP/calls"
: > "$TMP/auth-calls"
: > "$TMP/identity-calls"
set +e
output="$(PATH="$TMP/bin:$PATH" MOCK_DIR="$TMP" FAIL_STAGE=app-creation FAIL_STATUS=401 REFRESH_RESULT=fail run_phase_c 2>&1)"
code=$?
set -e
[ "$code" -ne 0 ] || fail "stale login unexpectedly succeeded"
printf '%s' "$output" | grep -Fq 'status=401' \
  || fail "401 diagnostic missing status: $output"
printf '%s' "$output" | grep -Fq 'live content was not updated' \
  || fail "401 did not explicitly preserve live content: $output"
pass 'failed refresh explicitly reports that live content was not updated'

echo '[6] malformed 2xx JSON fails schema validation before S3 upload'
: > "$TMP/calls"
: > "$TMP/auth-calls"
: > "$TMP/identity-calls"
set +e
output="$(PATH="$TMP/bin:$PATH" MOCK_DIR="$TMP" FAIL_STAGE=none INVALID_STAGE=deploy-creation run_phase_c 2>&1)"
code=$?
set -e
[ "$code" -ne 0 ] || fail "malformed deploy response unexpectedly succeeded"
[ "$(wc -l < "$TMP/calls" | tr -d ' ')" = 3 ] || fail "malformed deploy response attempted a later call: $output"
printf '%s' "$output" | grep -Fq 'stage=deploy-creation' \
  || fail "malformed response missing failed stage: $output"
printf '%s' "$output" | grep -Fq 'api_code=INVALID_SUCCESS_RESPONSE' \
  || fail "malformed response was not rejected by schema validation: $output"
pass 'malformed 2xx response is rejected before later calls'

assert_refresh_success() {
  local stage="$1" expected_calls="$2" output code
  : > "$TMP/calls"
  : > "$TMP/auth-calls"
  : > "$TMP/identity-calls"
  set +e
  output="$(PATH="$TMP/bin:$PATH" MOCK_DIR="$TMP" FAIL_STAGE=none REFRESH_STAGE="$stage" run_phase_c 2>&1)"
  code=$?
  set -e
  [ "$code" -eq 0 ] || fail "$stage did not continue after successful refresh: $output"
  [ "$(wc -l < "$TMP/calls" | tr -d ' ')" = "$expected_calls" ] \
    || fail "$stage successful refresh made the wrong number of requests: $output"
  [ "$(wc -l < "$TMP/identity-calls" | tr -d ' ')" = 1 ] \
    || fail "$stage did not refresh identity exactly once: $output"
  grep -Fxq -- '--force-refresh' "$TMP/identity-calls" \
    || fail "$stage did not force identity refresh"
  [ "$(grep -c "^$stage Authorization: Bearer $TOKEN$" "$TMP/auth-calls")" = 1 ] \
    || fail "$stage did not make exactly one request with the original token"
  [ "$(grep -c "^$stage Authorization: Bearer refreshed-secret-should-not-leak$" "$TMP/auth-calls")" = 1 ] \
    || fail "$stage did not retry exactly once with the refreshed token"
  pass "$stage refreshes once, retries once, and continues deployment"
}

echo '[7] 401 at deploy creation refreshes once and continues through completion'
assert_refresh_success deploy-creation 6

echo '[8] 401 at deploy completion refreshes once and finishes the publish'
assert_refresh_success deploy-completion 6

echo '[9] failed refresh stops after deploy creation and redacts diagnostics'
: > "$TMP/calls"
: > "$TMP/auth-calls"
: > "$TMP/identity-calls"
set +e
output="$(PATH="$TMP/bin:$PATH" MOCK_DIR="$TMP" FAIL_STAGE=none REFRESH_STAGE=deploy-creation REFRESH_RESULT=fail run_phase_c 2>&1)"
code=$?
set -e
[ "$code" -ne 0 ] || fail 'failed refresh unexpectedly continued'
[ "$(wc -l < "$TMP/calls" | tr -d ' ')" = 3 ] || fail "failed refresh ran a later deploy stage: $output"
[ "$(wc -l < "$TMP/identity-calls" | tr -d ' ')" = 1 ] || fail "failed refresh was attempted more than once: $output"
printf '%s' "$output" | grep -Fq 'live content was not updated' || fail "failed refresh omitted live-content outcome: $output"
printf '%s' "$output" | grep -Fq "$TOKEN" && fail "failed refresh leaked the original token: $output"
printf '%s' "$output" | grep -Fq 'refreshed-secret-should-not-leak' && fail "failed refresh leaked a refreshed token: $output"
printf '%s' "$output" | grep -Fq "$SIGNATURE" && fail "failed refresh leaked a presigned signature: $output"
pass 'failed refresh stops deployment with credential-redacted diagnostics'

echo '[10] 401 retry at completion is attempted once and then stops'
: > "$TMP/calls"
: > "$TMP/auth-calls"
: > "$TMP/identity-calls"
set +e
output="$(PATH="$TMP/bin:$PATH" MOCK_DIR="$TMP" FAIL_STAGE=none REFRESH_STAGE=deploy-completion RETRY_STATUS=401 run_phase_c 2>&1)"
code=$?
set -e
[ "$code" -ne 0 ] || fail 'failed completion retry unexpectedly succeeded'
[ "$(wc -l < "$TMP/calls" | tr -d ' ')" = 6 ] || fail "completion retry ran more than once: $output"
[ "$(grep -c '^POST http://api.test/api/deploys/deploy-1/complete$' "$TMP/calls")" = 2 ] \
  || fail "completion was not attempted exactly twice: $output"
[ "$(wc -l < "$TMP/identity-calls" | tr -d ' ')" = 1 ] || fail "completion refreshed more than once: $output"
printf '%s' "$output" | grep -Fq 'live content was not updated' || fail "failed retry omitted live-content outcome: $output"
printf '%s' "$output" | grep -Fq "$TOKEN" && fail "failed retry leaked the original token: $output"
printf '%s' "$output" | grep -Fq 'refreshed-secret-should-not-leak' && fail "failed retry leaked the refreshed token: $output"
printf '%s' "$output" | grep -Fq "$SIGNATURE" && fail "failed retry leaked a presigned signature: $output"
pass 'completion enforces one retry and redacts failed-retry diagnostics'

echo 'ALL PASS: deploy-api-request'
