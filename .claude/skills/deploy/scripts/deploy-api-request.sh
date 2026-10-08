#!/usr/bin/env bash
# deploy-api-request.sh — make one checked, diagnostic-safe deploy request.
#
# The deploy skill invokes this for each Phase C request. Successful response
# bodies go to stdout; failures go only to stderr and never include auth headers
# or presigned query parameters.

set -o pipefail

_src="${BASH_SOURCE[0]}"
_dir="${_src%/*}"
[ "$_dir" = "$_src" ] && _dir="."
SCRIPT_DIR="$(cd "$_dir" && pwd)"
IDENTITY_RESOLVER="${HQ_DEPLOY_IDENTITY_RESOLVER:-$SCRIPT_DIR/identity-resolve.sh}"

usage() {
  echo "usage: $0 --stage <stage> --method <method> --url <url> [--org <slug>] [--scope <scope>] [--header <header>] [--data <json>] [--upload-file <path>] [--form-string <name=value>] [--form-file <name=path>] [--expect <jq-expression>] [--no-auth]" >&2
  exit 64
}

STAGE=""
METHOD=""
URL=""
ORG=""
SCOPE=""
DATA=""
UPLOAD_FILE=""
FORM_STRINGS=()
FORM_FILES=()
EXPECT=""
USE_AUTH=1
HEADERS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage) STAGE="${2:-}"; shift 2 ;;
    --method) METHOD="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --org) ORG="${2:-}"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --header) HEADERS+=("${2:-}"); shift 2 ;;
    --data) DATA="${2:-}"; shift 2 ;;
    --upload-file) UPLOAD_FILE="${2:-}"; shift 2 ;;
    --form-string) FORM_STRINGS+=("${2:-}"); shift 2 ;;
    --form-file) FORM_FILES+=("${2:-}"); shift 2 ;;
    --expect) EXPECT="${2:-}"; shift 2 ;;
    --no-auth) USE_AUTH=0; shift ;;
    *) usage ;;
  esac
done

[ -n "$STAGE" ] && [ -n "$METHOD" ] && [ -n "$URL" ] || usage
if [ "$USE_AUTH" -eq 1 ] && [ -z "${HQ_DEPLOY_JWT:-}" ]; then
  echo "[deploy] stage=$STAGE request not sent: missing deploy identity" >&2
  exit 1
fi
if [ -n "$DATA" ] && [ -n "$UPLOAD_FILE" ]; then
  usage
fi
if { [ -n "$DATA" ] || [ -n "$UPLOAD_FILE" ]; } \
  && { [ "${#FORM_STRINGS[@]}" -gt 0 ] || [ "${#FORM_FILES[@]}" -gt 0 ]; }; then
  usage
fi
for form_value in "${FORM_STRINGS[@]}"; do
  case "$form_value" in *=*) [ -n "${form_value%%=*}" ] || usage ;; *) usage ;; esac
done
for form_file in "${FORM_FILES[@]}"; do
  case "$form_file" in
    *=*)
      [ -n "${form_file%%=*}" ] && [ -n "${form_file#*=}" ] || usage
      [ -f "${form_file#*=}" ] || usage
      ;;
    *) usage ;;
  esac
done

RESPONSE_BODY="$(mktemp -t hq-deploy-response.XXXXXX)"
CURL_ERRORS="$(mktemp -t hq-deploy-curl.XXXXXX)"
trap 'rm -f "$RESPONSE_BODY" "$CURL_ERRORS"' EXIT

sanitize_url() {
  local value="$1"
  value="${value%%\?*}"
  value="${value%%\#*}"
  printf '%s' "$value"
}

scrub_value() {
  local value="$1"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  if [ -n "${HQ_DEPLOY_JWT:-}" ]; then
    value="${value//"$HQ_DEPLOY_JWT"/[REDACTED]}"
  fi
  if [ -n "${REQUEST_TOKEN:-}" ]; then
    value="${value//"$REQUEST_TOKEN"/[REDACTED]}"
  fi
  if [ -n "${REFRESHED_TOKEN:-}" ]; then
    value="${value//"$REFRESHED_TOKEN"/[REDACTED]}"
  fi
  value="$(printf '%s' "$value" | sed -E \
    -e 's/([Bb]earer[[:space:]]+)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Aa]uthorization:[[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Xx]-[Aa]mz-([Ss]ignature|[Cc]redential|[Ss]ecurity-[Tt]oken)=)[^&[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Ss]ignature=)[^&[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Tt]oken=)[^&[:space:]]+/\1[REDACTED]/g')"
  printf '%.240s' "$value"
}

json_string() {
  jq -r "$1" "$RESPONSE_BODY" 2>/dev/null || true
}

diagnostic() {
  local status="$1" code="$2" message="$3" request_id="$4" extra=""
  local safe_stage safe_method safe_url safe_org safe_scope
  safe_stage="$(scrub_value "$STAGE")"
  safe_method="$(scrub_value "$METHOD")"
  safe_url="$(scrub_value "$(sanitize_url "$URL")")"
  safe_org="$(scrub_value "${ORG:--}")"
  safe_scope="$(scrub_value "${SCOPE:--}")"

  case "$status" in
    401) extra=" auth=stale-login action=live-content-not-updated" ;;
    403) extra=" authorization=forbidden" ;;
  esac
  [ -z "${AUTH_DIAGNOSTIC:-}" ] || extra="$AUTH_DIAGNOSTIC"

  printf '[deploy] stage=%s method=%s url=%s status=%s api_code=%s api_message=%s request_id=%s org=%s scope=%s%s\n' \
    "$safe_stage" "$safe_method" "$safe_url" "$status" \
    "$(scrub_value "$code")" "$(scrub_value "$message")" \
    "$(scrub_value "$request_id")" "$safe_org" "$safe_scope" "$extra" >&2
}

request_once() {
  local curl_args=(-sS -o "$RESPONSE_BODY" -w '%{http_code}' -X "$METHOD")
  if [ "$USE_AUTH" -eq 1 ]; then
    curl_args+=(-H "Authorization: Bearer $REQUEST_TOKEN")
  fi
  for header in "${HEADERS[@]}"; do
    curl_args+=(-H "$header")
  done
  if [ -n "$DATA" ]; then
    curl_args+=(--data "$DATA")
  elif [ -n "$UPLOAD_FILE" ]; then
    curl_args+=(--data-binary "@$UPLOAD_FILE")
  else
    for form_value in "${FORM_STRINGS[@]}"; do
      curl_args+=(--form-string "$form_value")
    done
    for form_file in "${FORM_FILES[@]}"; do
      form_name="${form_file%%=*}"
      form_path="${form_file#*=}"
      curl_args+=(--form "$form_name=@$form_path;type=application/gzip;filename=upload.tar.gz")
    done
  fi
  curl_args+=("$URL")

  : > "$RESPONSE_BODY"
  : > "$CURL_ERRORS"
  CURL_EXIT=0
  STATUS="$(curl "${curl_args[@]}" 2>"$CURL_ERRORS")" || CURL_EXIT=$?
}

REQUEST_TOKEN="${HQ_DEPLOY_JWT:-}"
REFRESHED_TOKEN=""
AUTH_DIAGNOSTIC=""
RETRIED=0
request_once
if [ "$CURL_EXIT" -ne 0 ] || ! [[ "$STATUS" =~ ^[0-9]{3}$ ]]; then
  diagnostic "${STATUS:-000}" "TRANSPORT_ERROR" "request failed before an HTTP response" "-"
  exit 1
fi

if [ "$USE_AUTH" -eq 1 ] && [ "$STATUS" = 401 ]; then
  REFRESH_JSON="$("$IDENTITY_RESOLVER" --force-refresh 2>/dev/null)" || REFRESH_JSON=""
  REFRESH_STATUS="$(printf '%s' "$REFRESH_JSON" | jq -r '.status // empty' 2>/dev/null || true)"
  REFRESHED_TOKEN="$(printf '%s' "$REFRESH_JSON" | jq -r '.jwt // empty' 2>/dev/null || true)"
  if [ "$REFRESH_STATUS" != ok ] || [ -z "$REFRESHED_TOKEN" ] \
    || [ "$REFRESHED_TOKEN" = "$REQUEST_TOKEN" ]; then
    AUTH_DIAGNOSTIC=" auth=refresh-failed action=live-content-not-updated"
    diagnostic 401 AUTH_REFRESH_FAILED "identity refresh failed; live content was not updated" "-"
    exit 1
  fi

  REQUEST_TOKEN="$REFRESHED_TOKEN"
  RETRIED=1
  request_once
  if [ "$CURL_EXIT" -ne 0 ] || ! [[ "$STATUS" =~ ^[0-9]{3}$ ]]; then
    AUTH_DIAGNOSTIC=" auth=refresh-retry-failed action=live-content-not-updated"
    diagnostic "${STATUS:-000}" "TRANSPORT_ERROR" "authentication retry failed; live content was not updated" "-"
    exit 1
  fi
fi

DB_WAIT_LIMIT="${HQ_DEPLOY_DB_WAIT_SECS:-600}"
DB_WAITED=0
while [ "$STATUS" = 503 ] \
  && [ "$(json_string '.code? // .error?.code? // empty')" = DATABASE_PROVISIONING ]; do
  DB_DELAY="$(json_string '(.retryAfterSeconds? // 5) | if type == "number" then floor else 5 end')"
  [[ "$DB_DELAY" =~ ^[0-9]+$ ]] || DB_DELAY=5
  [ "$DB_DELAY" -ge 2 ] || DB_DELAY=2
  [ "$DB_DELAY" -le 30 ] || DB_DELAY=30
  [ $((DB_WAITED + DB_DELAY)) -le "$DB_WAIT_LIMIT" ] || break
  echo "[deploy] stage=$STAGE the app database is being created (about two minutes the first time); repeating the same deploy in ${DB_DELAY}s" >&2
  "${HQ_DEPLOY_SLEEP_CMD:-sleep}" "$DB_DELAY"
  DB_WAITED=$((DB_WAITED + DB_DELAY))
  request_once
  if [ "$CURL_EXIT" -ne 0 ] || ! [[ "$STATUS" =~ ^[0-9]{3}$ ]]; then
    diagnostic "${STATUS:-000}" "TRANSPORT_ERROR" "request failed before an HTTP response" "-"
    exit 1
  fi
done

if [[ "$STATUS" != 2* ]]; then
  ERROR_CODE="$(json_string '(.error?.code? // .code? // .errorCode? // "HTTP_ERROR") | if type == "string" or type == "number" then tostring else "HTTP_ERROR" end')"
  ERROR_MESSAGE="$(json_string '((if (.error | type) == "string" then .error else (.error?.message? // empty) end) // .message? // .errorMessage? // "request failed") | if type == "string" and length > 0 then . else "request failed" end')"
  REQUEST_ID="$(json_string '(.requestId? // .request_id? // .error?.requestId? // .meta?.requestId? // "-") | if type == "string" or type == "number" then tostring else "-" end')"
  [ -n "$ERROR_CODE" ] || ERROR_CODE="HTTP_ERROR"
  [ -n "$ERROR_MESSAGE" ] || ERROR_MESSAGE="request failed"
  [ -n "$REQUEST_ID" ] || REQUEST_ID="-"
  if [ "$RETRIED" -eq 1 ]; then
    AUTH_DIAGNOSTIC=" auth=refresh-retry-failed action=live-content-not-updated"
    ERROR_MESSAGE="$ERROR_MESSAGE; live content was not updated"
  fi
  diagnostic "$STATUS" "$ERROR_CODE" "$ERROR_MESSAGE" "$REQUEST_ID"
  exit 1
fi

if [ -n "$EXPECT" ] && ! jq -e "$EXPECT" "$RESPONSE_BODY" >/dev/null 2>&1; then
  diagnostic "$STATUS" "INVALID_SUCCESS_RESPONSE" "response did not match expected schema" "-"
  exit 1
fi

cat "$RESPONSE_BODY"
