#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
REQUEST="$ROOT/.claude/skills/deploy/scripts/deploy-api-request.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin"

cat > "$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -u
out=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then out="$2"; shift 2; else shift; fi
done
printf '%s' "$FAKE_BODY" > "$out"
printf '%s' "$FAKE_STATUS"
STUB
chmod +x "$TMP_ROOT/bin/curl"

run_request() {
  FAKE_STATUS="$1" FAKE_BODY="$2" PATH="$TMP_ROOT/bin:$PATH" HQ_DEPLOY_JWT=test-jwt \
    "$REQUEST" --stage app-deploy --method POST --url https://api.example.test/api/apps/x/deploy
}

expect_diagnostic() {
  local name="$1" status="$2" body="$3" want="$4"
  local err="$TMP_ROOT/$name.err"
  if run_request "$status" "$body" >/dev/null 2>"$err"; then
    echo "FAIL ($name): expected a non-zero exit" >&2
    exit 1
  fi
  grep -qF -- "$want" "$err" || { echo "FAIL ($name): missing '$want' in: $(cat "$err")" >&2; exit 1; }
}

expect_diagnostic plain-string 500 '{"error":"App deploy failed: boom"}' 'api_message=App deploy failed: boom'
expect_diagnostic plain-string-code 409 '{"error":"Database apps cost $10 a month each.","code":"DATABASE_BILLING_ACK_REQUIRED"}' 'api_code=DATABASE_BILLING_ACK_REQUIRED api_message=Database apps cost $10 a month each.'
expect_diagnostic standard 409 '{"error":{"message":"needs acknowledgement","code":"DATABASE_BILLING_ACK_REQUIRED","status":409}}' 'api_code=DATABASE_BILLING_ACK_REQUIRED api_message=needs acknowledgement'
expect_diagnostic top-level-message 400 '{"message":"bad input"}' 'api_message=bad input'
expect_diagnostic empty-object 500 '{}' 'api_message=request failed'
expect_diagnostic not-json 502 'Bad Gateway' 'api_message=request failed'
expect_diagnostic empty-string 500 '{"error":""}' 'api_message=request failed'

echo 'deploy-api-request error body: ok'
