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
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  case "$arg" in
    -o) next=$((i + 1)); body_file="${!next}" ;;
    -X) next=$((i + 1)); method="${!next}" ;;
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
if [ "$stage" = "$FAIL_STAGE" ]; then
  status="${FAIL_STATUS:-403}"
  body='{"error":{"code":"FORBIDDEN","message":"Denied token-secret-should-not-leak X-Amz-Signature=presigned-secret-should-not-leak"},"requestId":"req-403"}'
elif [ "$stage" = "${INVALID_STAGE:-}" ]; then
  body='{"unexpected":true}'
fi
printf '%s' "$body" > "$body_file"
printf '%s' "$status"
STUB
chmod +x "$TMP/bin/curl"

run_phase_c() {
  local request app_response deploy_response presigned_url
  request() {
    HQ_DEPLOY_JWT="$TOKEN" "$SRC" --org acme --scope company --header 'X-Org-Slug: acme' "$@"
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

echo '[5] 401 is marked as the stale-login preview-only path'
: > "$TMP/calls"
set +e
output="$(PATH="$TMP/bin:$PATH" MOCK_DIR="$TMP" FAIL_STAGE=app-creation FAIL_STATUS=401 run_phase_c 2>&1)"
code=$?
set -e
[ "$code" -ne 0 ] || fail "stale login unexpectedly succeeded"
printf '%s' "$output" | grep -Fq 'status=401' \
  || fail "401 diagnostic missing status: $output"
printf '%s' "$output" | grep -Fq 'auth=stale-login action=preview-only' \
  || fail "401 did not surface stale-login handling: $output"
pass 'stale login follows the documented preview-only path'

echo '[6] malformed 2xx JSON fails schema validation before S3 upload'
: > "$TMP/calls"
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

echo 'ALL PASS: deploy-api-request'
