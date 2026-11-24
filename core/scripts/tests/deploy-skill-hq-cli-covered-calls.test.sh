#!/usr/bin/env bash
# deploy-skill-hq-cli-covered-calls.test.sh — /deploy sends the calls that
# hq-cli 5.345.238 covers through `hq deploy` (US-033 c1, first part): the
# host deploy history, the app read, the app upload, runtime bindings, the SSR
# registration, the comments toggle and the database enablement.
#
# Runs the real SKILL.md blocks against a mock `hq`. A stub deploy_request and
# a stub curl record any direct hq-deploy call; each case fails if one is made.
# A failed CLI call must stop the step: no upload marked done, no flag set.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/deploy/SKILL.md"
FAILS=0
fail() { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "  ok: $*"; }
[ -f "$SKILL" ] || { echo "FAIL: deploy skill is missing: $SKILL" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

echo "[0] SKILL.md has no deploy_request helper or call left"
if grep -Eq 'deploy_request( |\(\))' "$SKILL"; then
  fail "deploy_request still appears: $(grep -nE 'deploy_request( |\(\))' "$SKILL" | head -3)"
else
  pass "no deploy_request in SKILL.md"
fi
for stage in host-deploys app-url-read app-deploy secret-bindings app-read ssr-deploy comments-toggle db-enable app-read-record; do
  grep -Fq -- "--stage $stage" "$SKILL" && fail "stage $stage still sent as a direct hq-deploy request"
done
pass "none of the seven covered stages is sent as a direct hq-deploy request"

# block_with <fixed string>: the bash block (fenced at any indent) holding it.
block_with() {
  awk -v needle="$1" '
    /^ *```bash$/ { on = 1; buf = ""; hit = 0; next }
    on && /^ *```$/ { on = 0; if (hit) { printf "%s", buf; exit } next }
    on { buf = buf $0 "\n"; if (index($0, needle)) hit = 1 }
  ' "$SKILL"
}
HELPER_CODE="$(awk '/^command -v hq >\/dev\/null 2>&1/ {on = 1} on {print} on && /^if \[ "\$DEPLOY_SCOPE" = "personal" \]; then HQ_SCOPE_ARGS=/ {exit}' "$SKILL")"
HISTORY_CODE="$(block_with 'Stale-snapshot check for the chosen host')"
FIND_CODE="$(block_with 'Route mode already chose the host app')"
APP_UPLOAD_CODE="$(block_with 'if [ "$DEPLOY_TYPE" = "app" ]; then')"
BINDINGS_CODE="$(block_with '# List current bindings')"
SECRET_GATE_CODE="$(block_with 'BINDING_COUNT=0')"
SSR_CODE="$(block_with 'docker push')"
COMMENTS_CODE="$(block_with 'if [ "$COMMENTS" = "on" ] || [ "$COMMENTS" = "off" ]; then')"
DB_CODE="$(block_with 'DB_BILLING_ACK=true')"
for v in HELPER_CODE HISTORY_CODE FIND_CODE APP_UPLOAD_CODE BINDINGS_CODE SECRET_GATE_CODE SSR_CODE COMMENTS_CODE DB_CODE; do
  [ -n "${!v}" ] || { echo "FAIL: could not extract $v from SKILL.md (after $FAILS earlier failure(s))" >&2; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-skill-covered.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/work"

cat >"$TMP/bin/hq" <<'MOCK'
#!/usr/bin/env bash
# Mock hq. Logs argv and answers like hq-cli 5.345.238 `hq deploy ... --json`.
{ printf 'api=%s' "${HQ_DEPLOY_API_URL:-}"; printf ' [%s]' "$@"; printf '\n'; } >>"$LOG/hq"
[ "$1" = deploy ] || exit 2
sub="$2"; shift 2
case "$sub" in comments|runtime-bindings|access) sub="$sub-$1"; shift ;; esac
case " ${HQ_FAIL:-} " in *" $sub "*) echo "hq-deploy rejected the operation (HTTP 403)." >&2; exit 1 ;; esac
app="$1"
case "$sub" in
  history) if [ -n "${HISTORY_JSON:-}" ]; then printf '%s\n' "$HISTORY_JSON"; else printf '{"appId":"%s","deploys":[]}\n' "$app"; fi ;;
  app-info) printf '{"id":"%s","subdomain":"report","url":"%s","accessMode":"%s","passwordProtected":false,"privateMode":false}\n' \
    "$app" "${INFO_URL:-https://report.example.test}" "${STATE_MODE:-public}" ;;
  upload-app)
    if [ -n "${UPLOAD_RECEIPT:-}" ]; then printf '%s\n' "$UPLOAD_RECEIPT"
    else printf '{"appId":"%s","deployId":"dep-7","version":3,"status":"queued","statusUrl":"/api/apps/%s/deploys/dep-7/status"}\n' "$app" "$app"; fi ;;
  runtime-bindings-list) jq -nc --arg app "$app" --argjson n "${BINDING_N:-0}" \
    '{appId: $app, bindingVersion: 1, secrets: [range(0; $n) | {name: ("S" + tostring)}]}' ;;
  runtime-bindings-replace) printf '{"appId":"%s","bindingVersion":2,"secrets":[]}\n' "$app" ;;
  register-ssr) printf '{"deployId":"dep-s","version":1,"statusUrl":"/api/apps/%s/deploys/dep-s"}\n' "$app" ;;
  comments-toggle) printf '{"appId":"%s","commentsEnabled":%s}\n' "$app" "$([ "$2" = on ] && echo true || echo false)" ;;
  enable-database) printf '{"appId":"%s","database":true}\n' "$app" ;;
  create) printf '{"id":"app-new","subdomain":"%s"}\n' "$app" ;;
  *) echo "mock hq: unknown deploy command $sub" >&2; exit 2 ;;
esac
MOCK
cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
echo "curl $*" >>"$LOG/direct"; printf '000'; exit 7
MOCK
for tool in aws docker; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$LOG/tools"\nexit 0\n' "$tool" >"$TMP/bin/$tool"
done
chmod +x "$TMP/bin/"*

# run_block <case> <code>: runs one block in a fresh shell; writes $LOG/vars.
run_block() {
  local name="$1" code="$2"
  export LOG="$TMP/log-$name"
  rm -rf "$LOG"; mkdir -p "$LOG/tmp"
  ( cd "$TMP/work" && PATH="$TMP/bin:$PATH" TMPDIR="$LOG/tmp" CODE="$code" HELPER_CODE="$HELPER_CODE" bash -c '
    set -uo pipefail
    deploy_request() { echo "deploy_request $*" >>"$LOG/direct"; return 1; }
    API=https://api.test JWT=jwt DEPLOY_CONTEXT_ARGS=()
    : "${ORG_SLUG=}" "${DEPLOY_SCOPE=company}" "${ROUTE_MODE=false}" "${APP_NAME=report}"
    : "${DEPLOY_TYPE=static}" "${APP_ID=app-1}" "${APP_SUBDOMAIN=report}" "${APP_URL=}"
    : "${OUTPUT_DIR=$LOG}" "${TARBALL_PATH=$LOG/site.tar.gz}" "${COMPANY_UID=cmp_1}"
    : "${VERSION=v3}" "${ECR_URI=ecr.test}" "${COMMENTS=}"
    [ -n "${HOST:-}" ] || HOST="{}"
    [ -n "${APPS_JSON:-}" ] || APPS_JSON="{\"apps\":[]}"
    eval "$HELPER_CODE"
    eval "$CODE"
    rc=$?
    for v in APP_ID APP_URL UPLOAD_OK LIVE_URL ROUTE_BLOCKER LIVE_DEPLOY_ID ACCESS_MODE BINDING_COUNT DB_BILLING_ACK; do
      printf "%s=%s\n" "$v" "${!v:-}"
    done >"$LOG/vars"
    exit "$rc"
  ' >"$LOG/out" 2>"$LOG/err" )
}
var() { sed -n "s/^$1=//p" "$LOG/vars" 2>/dev/null; }
no_direct() { [ ! -s "$LOG/direct" ] || { fail "$1: direct call: $(head -1 "$LOG/direct")"; return 1; }; }
hq_called() { grep -Fq -- "$1" "$LOG/hq" 2>/dev/null; }

echo "[1] Host deploy history goes through hq deploy history"
HOST_JSON='{"appId":"app-h","deployId":"dep-2"}'
HIST='{"appId":"app-h","deploys":[{"id":"dep-1","status":"live","createdAt":"2026-11-01T00:00:00Z"},{"id":"dep-2","status":"live","createdAt":"2026-11-02T00:00:00Z"},{"id":"dep-3","status":"failed","createdAt":"2026-11-03T00:00:00Z"}]}'
ORG_SLUG=acme HOST="$HOST_JSON" HISTORY_JSON="$HIST" run_block hist-current "$HISTORY_CODE"
hq_called 'api=https://api.test [deploy] [history] [app-h] [--company] [acme] [--json]' \
  && pass "history app-h --company acme --json, API base passed" || fail "history argv: $(cat "$LOG/hq" 2>/dev/null)"
[ "$(var LIVE_DEPLOY_ID)" = dep-2 ] && [ -z "$(var ROUTE_BLOCKER)" ] \
  && pass "newest non-failed deploy matches the snapshot: no blocker" || fail "LIVE=$(var LIVE_DEPLOY_ID) BLOCKER=$(var ROUTE_BLOCKER)"
no_direct hist-current && pass "no direct GET /deploys"

HIST_NEWER='{"appId":"app-h","deploys":[{"id":"dep-2","status":"live","createdAt":"2026-11-02T00:00:00Z"},{"id":"dep-4","status":"pending","createdAt":"2026-11-04T00:00:00Z"}]}'
DEPLOY_SCOPE=personal HOST="$HOST_JSON" HISTORY_JSON="$HIST_NEWER" run_block hist-stale "$HISTORY_CODE"
hq_called '[history] [app-h] [--personal] [--json]' && pass "personal scope sends --personal" || fail "personal argv: $(cat "$LOG/hq" 2>/dev/null)"
[ "$(var ROUTE_BLOCKER)" = stale_snapshot ] && pass "a newer in-flight deploy is stale" || fail "BLOCKER=$(var ROUTE_BLOCKER)"

SINGLE='{"appId":"app-h","deploymentModel":"single-live","currentDeployment":{"deploymentId":"dep-2","status":"live","createdAt":"2026-11-02T00:00:00Z"}}'
ORG_SLUG=acme HOST="$HOST_JSON" HISTORY_JSON="$SINGLE" run_block hist-single "$HISTORY_CODE"
[ "$(var LIVE_DEPLOY_ID)" = dep-2 ] && [ -z "$(var ROUTE_BLOCKER)" ] \
  && pass "single-live history shape is read" || fail "single-live LIVE=$(var LIVE_DEPLOY_ID) BLOCKER=$(var ROUTE_BLOCKER)"

ORG_SLUG=acme HOST="$HOST_JSON" HQ_FAIL=history run_block hist-fail "$HISTORY_CODE"
[ "$(var ROUTE_BLOCKER)" = stale_snapshot ] && pass "a failed history read blocks route mode" || fail "BLOCKER=$(var ROUTE_BLOCKER)"
no_direct hist-fail && pass "no direct retry"

echo "[2] A created app with no url is re-read with hq deploy app-info"
ORG_SLUG=acme APP_ID="" APP_SUBDOMAIN="" INFO_URL=https://report.example.test/ run_block find-reread "$FIND_CODE"
hq_called '[app-info] [app-new] [--company] [acme] [--json]' && pass "app-info app-new --company acme --json" \
  || fail "app-info argv: $(cat "$LOG/hq" 2>/dev/null)"
[ "$(var APP_URL)" = https://report.example.test ] && pass "APP_URL from app-info, trailing slash trimmed" || fail "APP_URL=$(var APP_URL)"
no_direct find-reread && pass "no direct GET /api/apps/:id"

echo "[3] App upload goes through hq deploy upload-app"
ORG_SLUG=acme DEPLOY_TYPE=app APP_URL=https://report.example.test run_block app-up "$APP_UPLOAD_CODE"
rc=$?
[ "$rc" = 0 ] || fail "app upload exited $rc: $(cat "$LOG/err")"
grep -Eq "\[upload-app\] \[app-1\] \[[^]]*/site\.tar\.gz\] \[--company\] \[acme\] \[--json\]$" "$LOG/hq" \
  && pass "upload-app app-1 <tarball> --company acme --json, no acknowledgement flags" || fail "upload-app argv: $(cat "$LOG/hq" 2>/dev/null)"
[ "$(var UPLOAD_OK)" = true ] && [ "$(var LIVE_URL)" = https://report.example.test ] \
  && pass "UPLOAD_OK and the API-returned LIVE_URL" || fail "UPLOAD_OK=$(var UPLOAD_OK) LIVE_URL=$(var LIVE_URL)"
no_direct app-up && pass "no direct POST /api/apps/:id/deploy"

DEPLOY_SCOPE=personal DEPLOY_TYPE=app DB_BILLING_ACK=true PUBLIC_SECRET_RISK_ACK=true run_block app-up-ack "$APP_UPLOAD_CODE"
hq_called '[--personal] [--acknowledge-database-billing] [--acknowledge-public-secret-risk] [--json]' \
  && pass "personal upload passes both acknowledgements" || fail "ack argv: $(cat "$LOG/hq" 2>/dev/null)"

ORG_SLUG=acme DEPLOY_TYPE=app HQ_FAIL=upload-app run_block app-up-fail "$APP_UPLOAD_CODE"
rc=$?
[ "$rc" != 0 ] && [ -z "$(var UPLOAD_OK)" ] && pass "a failed upload exits $rc with UPLOAD_OK unset" || fail "upload failure rc=$rc UPLOAD_OK=$(var UPLOAD_OK)"

ORG_SLUG=acme DEPLOY_TYPE=app UPLOAD_RECEIPT='{"appId":"app-1","status":"queued"}' run_block app-up-bad "$APP_UPLOAD_CODE"
rc=$?
[ "$rc" != 0 ] && [ -z "$(var UPLOAD_OK)" ] && grep -Fq 'no deploy receipt' "$LOG/err" \
  && pass "a receipt with no deployId exits $rc with UPLOAD_OK unset" || fail "bad receipt rc=$rc UPLOAD_OK=$(var UPLOAD_OK)"

echo "[4] Runtime bindings go through hq deploy runtime-bindings (company only)"
ORG_SLUG=acme BINDING_N=2 run_block bindings "$BINDINGS_CODE"
rc=$?
[ "$rc" = 0 ] || fail "bindings exited $rc: $(cat "$LOG/err")"
hq_called '[runtime-bindings] [list] [app-1] [--company] [acme] [--json]' && pass "runtime-bindings list app-1 --company acme --json" \
  || fail "list argv: $(cat "$LOG/hq" 2>/dev/null)"
hq_called '[runtime-bindings] [replace] [app-1] [--company] [acme] [--company-uid] [cmp_1] [--ref] [SLACK_WEBHOOK_URL] [--ref] [DATABASE_URL] [--confirm-replace] [--json]' \
  && pass "replace sends the company uid, every ref and --confirm-replace" || fail "replace argv: $(cat "$LOG/hq" 2>/dev/null)"
grep -Fq -- '--personal' "$LOG/hq" && fail "bindings sent --personal" || pass "bindings never send --personal"
no_direct bindings && pass "no direct /secret-bindings call"

echo "[5] Public + secret gate reads the app and its bindings through hq"
ORG_SLUG=acme STATE_MODE=public BINDING_N=2 run_block gate-company "$SECRET_GATE_CODE"
[ "$(var ACCESS_MODE)" = public ] && [ "$(var BINDING_COUNT)" = 2 ] \
  && pass "company: accessMode public, 2 bindings" || fail "ACCESS_MODE=$(var ACCESS_MODE) BINDING_COUNT=$(var BINDING_COUNT)"
hq_called '[app-info] [app-1] [--company] [acme] [--json]' && hq_called '[runtime-bindings] [list] [app-1] [--company] [acme] [--json]' \
  && pass "app-info and runtime-bindings list" || fail "gate argv: $(cat "$LOG/hq" 2>/dev/null)"
no_direct gate-company && pass "no direct call"

DEPLOY_SCOPE=personal STATE_MODE=public run_block gate-personal "$SECRET_GATE_CODE"
[ "$(var BINDING_COUNT)" = 0 ] && ! grep -Fq 'runtime-bindings' "$LOG/hq" \
  && pass "personal: no bindings call, count 0" || fail "personal BINDING_COUNT=$(var BINDING_COUNT) hq: $(cat "$LOG/hq")"

ORG_SLUG=acme HQ_FAIL=app-info run_block gate-fail "$SECRET_GATE_CODE"
rc=$?
[ "$rc" != 0 ] && pass "a failed app read stops ($rc)" || fail "app-info failure did not stop"
ORG_SLUG=acme HQ_FAIL=runtime-bindings-list run_block gate-bind-fail "$SECRET_GATE_CODE"
rc=$?
[ "$rc" != 0 ] && pass "a failed bindings read stops ($rc)" || fail "bindings failure did not stop"

echo "[6] SSR registration goes through hq deploy register-ssr"
ORG_SLUG=acme run_block ssr "$SSR_CODE"
rc=$?
[ "$rc" = 0 ] || fail "ssr exited $rc: $(cat "$LOG/err")"
hq_called '[register-ssr] [app-1] [v3] [--company] [acme] [--json]' && pass "register-ssr app-1 v3 --company acme --json" \
  || fail "register-ssr argv: $(cat "$LOG/hq" 2>/dev/null)"
no_direct ssr && pass "no direct POST /api/apps/:id/deploy"
ORG_SLUG=acme HQ_FAIL=register-ssr run_block ssr-fail "$SSR_CODE"
rc=$?
[ "$rc" != 0 ] && pass "a failed registration exits $rc" || fail "register-ssr failure did not stop"

echo "[7] Comments toggle goes through hq deploy comments toggle"
ORG_SLUG=acme COMMENTS=on run_block comments-on "$COMMENTS_CODE"
hq_called '[comments] [toggle] [app-1] [on] [--company] [acme] [--json]' && pass "comments toggle app-1 on --company acme" \
  || fail "toggle argv: $(cat "$LOG/hq" 2>/dev/null)"
no_direct comments-on && pass "no direct PATCH /api/apps/:id"
DEPLOY_SCOPE=personal COMMENTS=off run_block comments-off "$COMMENTS_CODE"
hq_called '[comments] [toggle] [app-1] [off] [--personal] [--json]' && pass "comments toggle off --personal" \
  || fail "toggle off argv: $(cat "$LOG/hq" 2>/dev/null)"
ORG_SLUG=acme COMMENTS="" run_block comments-unset "$COMMENTS_CODE"
[ ! -s "$LOG/hq" ] && pass "no --comments intent: no call" || fail "called without an intent: $(cat "$LOG/hq")"
ORG_SLUG=acme COMMENTS=on HQ_FAIL=comments-toggle run_block comments-fail "$COMMENTS_CODE"
rc=$?
[ "$rc" != 0 ] && pass "a failed toggle exits $rc" || fail "toggle failure did not stop"

echo "[8] Database enablement goes through hq deploy enable-database"
ORG_SLUG=acme run_block db "$DB_CODE"
hq_called '[enable-database] [app-1] [--company] [acme] [--acknowledge-database-billing] [--json]' \
  && pass "enable-database app-1 --company acme --acknowledge-database-billing" || fail "db argv: $(cat "$LOG/hq" 2>/dev/null)"
[ "$(var DB_BILLING_ACK)" = true ] && pass "DB_BILLING_ACK set after the call" || fail "DB_BILLING_ACK=$(var DB_BILLING_ACK)"
no_direct db && pass "no direct PATCH /api/apps/:id"
ORG_SLUG=acme HQ_FAIL=enable-database run_block db-fail "$DB_CODE"
rc=$?
[ "$rc" != 0 ] && [ -z "$(var DB_BILLING_ACK)" ] && pass "a failed enablement exits $rc before DB_BILLING_ACK" \
  || fail "db failure rc=$rc DB_BILLING_ACK=$(var DB_BILLING_ACK)"

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: deploy-skill-hq-cli-covered-calls ($FAILS)" >&2
  exit 1
fi
echo "ALL PASS: deploy-skill-hq-cli-covered-calls"
