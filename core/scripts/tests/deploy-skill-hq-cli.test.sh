#!/usr/bin/env bash
# deploy-skill-hq-cli.test.sh — /deploy runs app creation, the C.3 access
# gates, the static upload, the gate re-read and the takedown through
# `hq deploy`, not through its own curl/deploy_request copies.
#
# Runs the real SKILL.md blocks against a mock `hq`. A stub deploy_request and
# a stub curl record any direct hq-deploy or vault call; each case fails if one
# is made. Failure paths must stop: no upload, no weaker gate.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/deploy/SKILL.md"
FAILS=0
fail() { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "  ok: $*"; }
[ -f "$SKILL" ] || { echo "FAIL: deploy skill is missing: $SKILL" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

block_after() {  # block_after <heading prefix>: first bash block under the heading
  awk -v h="$1" '
    index($0, h) == 1 { on = 1; next }
    on && /^```bash$/ { code = 1; next }
    code && /^```$/ { exit }
    code { print }
  ' "$SKILL"
}
HELPER_CODE="$(awk '/^command -v hq >\/dev\/null 2>&1/ {on = 1} on {print} on && /^if \[ "\$DEPLOY_SCOPE" = "personal" \]; then HQ_SCOPE_ARGS=/ {exit}' "$SKILL")"
FIND_CODE="$(block_after '#### Find or create the app')"
GATE_CODE="$(block_after '#### C.3 — Wire access mode BEFORE upload')"
STATIC_CODE="$(block_after '#### Static upload')"
VERIFY_CODE="$(block_after '#### Auth-gate verify')"
for v in FIND_CODE GATE_CODE STATIC_CODE VERIFY_CODE; do
  [ -n "${!v}" ] || { echo "FAIL: could not extract $v from SKILL.md" >&2; exit 1; }
done
[ -n "$HELPER_CODE" ] || fail "SKILL.md defines no hq_deploy helper with a scope array"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-skill-hq-cli.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/work/.claude/skills/deploy/scripts"

# Stub helper scripts the blocks call by relative path.
for s in route-host.sh password-helper.sh; do
  printf '#!/usr/bin/env bash\necho "$0 $*" >>"$LOG/scripts"\nexit 0\n' \
    >"$TMP/work/.claude/skills/deploy/scripts/$s"
  chmod +x "$TMP/work/.claude/skills/deploy/scripts/$s"
done

cat >"$TMP/bin/hq" <<'MOCK'
#!/usr/bin/env bash
# Mock hq. Logs argv and the API base, answers like the real hq deploy --json.
{ printf 'api=%s' "${HQ_DEPLOY_API_URL:-}"; printf ' [%s]' "$@"; printf '\n'; } >>"$LOG/hq"
[ "$1" = deploy ] || exit 2
sub="$2"; shift 2
[ "$sub" = access ] && [ "${1:-}" = get ] && { sub=access-get; shift; }
case " ${HQ_FAIL:-} " in *" $sub "*) echo "hq-deploy rejected the operation (HTTP 403)." >&2; exit 1 ;; esac
app="$1"; shift
mode=""; pwfile=""; edits='{"addUser":[],"removeUser":[],"addGroup":[],"removeGroup":[]}'
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift ;;
    --password-file) pwfile="$2"; shift ;;
    --add-user) edits=$(jq -c --arg v "$2" '.addUser += [$v]' <<<"$edits"); shift ;;
    --remove-user) edits=$(jq -c --arg v "$2" '.removeUser += [$v]' <<<"$edits"); shift ;;
    --add-group) edits=$(jq -c --arg v "$2" '.addGroup += [$v]' <<<"$edits"); shift ;;
    --remove-group) edits=$(jq -c --arg v "$2" '.removeGroup += [$v]' <<<"$edits"); shift ;;
  esac
  shift
done
# ACCESS_STATE (optional) holds the saved access policy across runs, so a case
# can deploy twice to the same app. `access` applies edits the way hq-cli's
# applyEdits does: drop removed ids, append added ids not already present.
# MOCK_IGNORE_REMOVE=1 simulates a server that keeps removed members.
if [ "$sub" = access ] && [ -n "${ACCESS_STATE:-}" ]; then
  [ -s "$ACCESS_STATE" ] || echo '{"mode":"company","companyUid":"cmp_1","users":[],"groups":[]}' >"$ACCESS_STATE"
  [ "${MOCK_IGNORE_REMOVE:-}" = 1 ] && edits=$(jq -c '.removeUser = [] | .removeGroup = []' <<<"$edits")
  jq -c --arg mode "$mode" --argjson e "$edits" '
    def apply($cur; $add; $rm): ([$cur[].id | select(. as $i | $rm | index($i) | not)]) as $keep
      | ($keep + [$add[] | select(. as $i | ($keep | index($i) | not) and ($rm | index($i) | not))]) | unique | map({id: .});
    .mode = $mode | .users = apply(.users; $e.addUser; $e.removeUser) | .groups = apply(.groups; $e.addGroup; $e.removeGroup)
  ' "$ACCESS_STATE" >"$ACCESS_STATE.new" && mv "$ACCESS_STATE.new" "$ACCESS_STATE"
  jq -c --arg app "$app" '{company: "acme", app: $app, policy: .}' "$ACCESS_STATE"
  exit 0
fi
if [ "$sub" = access-get ] && [ -n "${ACCESS_STATE:-}" ]; then
  [ -s "$ACCESS_STATE" ] || echo '{"mode":"company","companyUid":"cmp_1","users":[],"groups":[]}' >"$ACCESS_STATE"
  jq -c --arg app "$app" '{company: "acme", app: $app, policy: .}' "$ACCESS_STATE"
  exit 0
fi
case "$sub" in
  create) printf '{"id":"app-new","subdomain":"%s","url":"https://%s.example.test"}\n' "$app" "$app" ;;
  password-gate)
    cp "$pwfile" "$LOG/pw-content"; printf '%s' "$pwfile" >"$LOG/pw-path"
    ls -l "$pwfile" | cut -c1-10 >"$LOG/pw-perms"
    printf '{"app":"%s","mode":"password"}\n' "$app" ;;
  private-gate) printf '{"app":"%s","mode":"private"}\n' "$app" ;;
  access) printf '{"company":"acme","app":"%s","policy":{"mode":"%s","companyUid":"cmp_1","users":[],"groups":[]}}\n' "$app" "$mode" ;;
  access-get) printf '{"company":"acme","app":"%s","policy":{"mode":"%s","companyUid":"%s"}}\n' "$app" "${POLICY_MODE:-company}" "${POLICY_UID:-cmp_1}" ;;
  upload) printf '{"url":"https://%s.example.test","deployId":"dep-9"}\n' "$app" ;;
  inspect) printf '{"id":"%s","accessMode":"%s","passwordProtected":%s,"privateMode":%s}\n' \
    "$app" "${STATE_MODE:-}" "${STATE_PROTECTED:-false}" "${STATE_PRIVATE:-false}" ;;
  takedown) printf '{"app":"%s","active":false}\n' "$app" ;;
  *) echo "mock hq: unknown deploy command $sub" >&2; exit 2 ;;
esac
MOCK
cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
# Only anonymous GETs of the live app URL are allowed; anything else is a
# direct API call the skill should have made through hq.
url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  https://*.example.test/*) printf '%s' "${EDGE_CODE:-302}" ;;
  *) echo "curl $*" >>"$LOG/direct"; printf '000'; exit 7 ;;
esac
MOCK
chmod +x "$TMP/bin/hq" "$TMP/bin/curl"

# run_block <case> <code...>: runs the blocks in a fresh shell in $TMP/work.
# Env for the blocks comes from the caller. Prints the shell's exports file.
run_block() {
  local name="$1"; shift
  export LOG="$TMP/log-$name"
  rm -rf "$LOG"; mkdir -p "$LOG/tmp"
  local code; code="$(printf '%s\n' "$@")"
  ( cd "$TMP/work" && PATH="$TMP/bin:$PATH" TMPDIR="$LOG/tmp" CODE="$code" HELPER_CODE="$HELPER_CODE" bash -c '
    set -uo pipefail
    deploy_request() { echo "deploy_request $*" >>"$LOG/direct"; return 1; }
    sleep() { :; }
    API=https://api.test VAULT_API=https://vault.test JWT=jwt HQ_PRO_JWT=""
    HQ_PRO_REQUEST_HEADERS=() DEPLOY_CONTEXT_ARGS=()
    : "${ORG_SLUG:=}" "${DEPLOY_SCOPE:=company}" "${ROUTE_MODE:=false}" "${APP_NAME:=report}"
    : "${DEPLOY_TYPE:=static}" "${SENSITIVE:=false}" "${ACCESS_MODE:=public}" "${PW:=}"
    : "${APP_ID:=}" "${APP_SUBDOMAIN:=report}" "${APP_URL:=}" "${LIVE_URL:=}" "${KEEP_OUT:=}" "${ROUTE_OUT:=}"
    : "${OUTPUT_DIR:=$LOG}" "${TARBALL_PATH:=$LOG/site.tar.gz}" "${HOST_ACCESS_MODE:=}" "${MERGE_JSON:={}}"
    : "${ALLOW_PATTERNS:=}"
    eval "$HELPER_CODE"
    eval "$CODE"
    rc=$?
    printf "APP_ID=%s\nDEPLOY_ID=%s\nLIVE_URL=%s\nUPLOAD_OK=%s\nCOMPANY_UID=%s\n" \
      "${APP_ID:-}" "${DEPLOY_ID:-}" "${LIVE_URL:-}" "${UPLOAD_OK:-}" "${COMPANY_UID:-}" >"$LOG/vars"
    exit "$rc"
  ' >"$LOG/out" 2>"$LOG/err" )
}
var() { sed -n "s/^$1=//p" "$LOG/vars" 2>/dev/null; }
no_direct() { [ ! -s "$LOG/direct" ] || { fail "$1: direct call: $(head -1 "$LOG/direct")"; return 1; }; }
hq_called() { grep -Fq -- "$1" "$LOG/hq" 2>/dev/null; }

echo "[1] Find or create: a new company app is created by hq deploy create"
ORG_SLUG=acme APPS_JSON='{"apps":[]}' run_block find-company "$FIND_CODE"
rc=$?
[ "$rc" = 0 ] || fail "find-company exited $rc: $(cat "$LOG/err")"
hq_called 'api=https://api.test [deploy] [create] [report] [--type] [static] [--company] [acme] [--json]' \
  && pass "hq deploy create report --type static --company acme --json, API base passed" \
  || fail "create argv: $(cat "$LOG/hq" 2>/dev/null)"
[ "$(var APP_ID)" = app-new ] && pass "APP_ID from the create output" || fail "APP_ID=$(var APP_ID)"
no_direct find-company && pass "no direct POST /api/apps"

echo "[2] Find or create: personal scope sends --personal"
DEPLOY_SCOPE=personal APPS_JSON='{"apps":[]}' run_block find-personal "$FIND_CODE"
hq_called '[create] [report] [--type] [static] [--personal] [--json]' && ! grep -Fq -- '--company' "$LOG/hq" \
  && pass "personal create uses --personal and no --company" || fail "personal argv: $(cat "$LOG/hq" 2>/dev/null)"
no_direct find-personal && pass "no direct call"

echo "[3] Find or create: a failed create stops"
ORG_SLUG=acme HQ_FAIL=create APPS_JSON='{"apps":[]}' run_block find-fail "$FIND_CODE"
rc=$?
[ "$rc" != 0 ] && [ -z "$(var APP_ID)" ] && pass "create failure exits $rc with no APP_ID" || fail "create failure rc=$rc APP_ID=$(var APP_ID)"
no_direct find-fail && pass "no direct retry"

echo "[4] C.3 password: hq deploy password-gate reads the password from a private file"
ORG_SLUG=acme APP_ID=app-1 SENSITIVE=true ACCESS_MODE=password PW=foxtrot-river-92 run_block gate-password "$GATE_CODE"
rc=$?
[ "$rc" = 0 ] || fail "password gate exited $rc: $(cat "$LOG/err")"
hq_called '[password-gate] [app-1] [--company] [acme] [--password-file]' && pass "password-gate app-1 --company acme --password-file" \
  || fail "password-gate argv: $(cat "$LOG/hq" 2>/dev/null)"
grep -Fq foxtrot-river-92 "$LOG/hq" && fail "the password is on the hq command line" || pass "the password is not in argv"
[ "$(cat "$LOG/pw-content" 2>/dev/null)" = foxtrot-river-92 ] && pass "the file holds the password" || fail "password file content wrong"
[ "$(cat "$LOG/pw-perms" 2>/dev/null)" = "-rw-------" ] && pass "the file is owner-only" || fail "password file perms: $(cat "$LOG/pw-perms" 2>/dev/null)"
[ ! -e "$(cat "$LOG/pw-path" 2>/dev/null)" ] && pass "the file is removed" || fail "password file left behind"
no_direct gate-password && pass "no direct POST /access-mode"

echo "[5] C.3 password: a failed password-gate stops"
ORG_SLUG=acme APP_ID=app-1 SENSITIVE=true ACCESS_MODE=password PW=pw-1 HQ_FAIL=password-gate run_block gate-password-fail "$GATE_CODE"
rc=$?
[ "$rc" != 0 ] && pass "exits $rc" || fail "password-gate failure did not stop"
[ -z "$(ls -A "$LOG/tmp")" ] && pass "no password file left" || fail "password file left: $(ls "$LOG/tmp")"

echo "[6] C.3 company: hq deploy access --mode company; no vault or policy curl"
ORG_SLUG=acme APP_ID=app-1 SENSITIVE=true ACCESS_MODE=company run_block gate-company "$GATE_CODE"
rc=$?
[ "$rc" = 0 ] || fail "company gate exited $rc: $(cat "$LOG/err")"
hq_called '[access] [app-1] [--company] [acme] [--mode] [company] [--yes] [--json]' \
  && pass "access app-1 --company acme --mode company --yes --json" || fail "access argv: $(cat "$LOG/hq" 2>/dev/null)"
[ "$(var COMPANY_UID)" = cmp_1 ] && pass "COMPANY_UID from the returned policy" || fail "COMPANY_UID=$(var COMPANY_UID)"
no_direct gate-company && pass "no vault lookup or PUT /access-policy"

echo "[7] C.3 company: a failed access call stops and never sets a password"
ORG_SLUG=acme APP_ID=app-1 SENSITIVE=true ACCESS_MODE=company HQ_FAIL=access run_block gate-company-fail "$GATE_CODE"
rc=$?
[ "$rc" != 0 ] && pass "exits $rc" || fail "company gate failure did not stop"
hq_called '[password-gate]' && fail "fell back to a password gate" || pass "no password-gate call"
grep -Fq 'NOT uploaded' "$LOG/err" && pass "reports that nothing new was uploaded" || fail "no exposure report: $(cat "$LOG/err")"

echo "[8] C.3 selected: members become --add-user / --add-group"
export ACCESS_STATE="$TMP/access-state-1.json"
ORG_SLUG=acme APP_ID=app-1 SENSITIVE=true ACCESS_MODE=selected \
  SELECTED_USERS_JSON='[{"id":"person_a"},{"id":"person_b"}]' SELECTED_GROUPS_JSON='[{"id":"grp_1"}]' \
  run_block gate-selected "$GATE_CODE"
rc=$?
[ "$rc" = 0 ] || fail "selected gate exited $rc: $(cat "$LOG/err")"
hq_called '[access] [get] [app-1] [--company] [acme] [--json]' \
  && pass "reads the current policy before writing" || fail "no access get: $(cat "$LOG/hq" 2>/dev/null)"
hq_called '[access] [app-1] [--company] [acme] [--mode] [selected] [--add-user] [person_a] [--add-user] [person_b] [--add-group] [grp_1] [--yes] [--json]' \
  && pass "selected members passed as flags" || fail "selected argv: $(cat "$LOG/hq" 2>/dev/null)"
no_direct gate-selected && pass "no direct PUT /access-policy"

echo "[8b] C.3 selected: redeploy A+B then A only removes B (exact audience)"
ORG_SLUG=acme APP_ID=app-1 SENSITIVE=true ACCESS_MODE=selected \
  SELECTED_USERS_JSON='[{"id":"person_a"}]' SELECTED_GROUPS_JSON='[]' \
  run_block gate-selected-shrink "$GATE_CODE"
rc=$?
[ "$rc" = 0 ] || fail "shrink redeploy exited $rc: $(cat "$LOG/err")"
hq_called '[access] [app-1] [--company] [acme] [--mode] [selected] [--remove-user] [person_b] [--remove-group] [grp_1] [--add-user] [person_a] [--yes] [--json]' \
  && pass "stale person_b and grp_1 passed as --remove-user / --remove-group" || fail "shrink argv: $(cat "$LOG/hq" 2>/dev/null)"
[ "$(jq -c '[.users[].id]' "$ACCESS_STATE")" = '["person_a"]' ] && [ "$(jq -c '[.groups[].id]' "$ACCESS_STATE")" = '[]' ] \
  && pass "saved policy is exactly person_a; person_b no longer has access" || fail "saved policy: $(cat "$ACCESS_STATE")"

echo "[8c] C.3 selected: stale access left by the server fails loudly"
export ACCESS_STATE="$TMP/access-state-2.json"
echo '{"mode":"selected","companyUid":"cmp_1","users":[{"id":"person_a"},{"id":"person_b"}],"groups":[]}' >"$ACCESS_STATE"
ORG_SLUG=acme APP_ID=app-1 SENSITIVE=true ACCESS_MODE=selected MOCK_IGNORE_REMOVE=1 \
  SELECTED_USERS_JSON='[{"id":"person_a"}]' SELECTED_GROUPS_JSON='[]' \
  run_block gate-selected-stale "$GATE_CODE"
rc=$?
[ "$rc" != 0 ] && pass "exits $rc when person_b is still in the saved policy" || fail "stale access reported success"
grep -Fq 'does not match the requested audience' "$LOG/err" && pass "names the audience mismatch" || fail "no mismatch message: $(cat "$LOG/err")"

echo "[8d] C.3 selected: a failed policy read stops before any write"
export ACCESS_STATE="$TMP/access-state-3.json"
ORG_SLUG=acme APP_ID=app-1 SENSITIVE=true ACCESS_MODE=selected HQ_FAIL=access-get \
  SELECTED_USERS_JSON='[{"id":"person_a"}]' SELECTED_GROUPS_JSON='[]' \
  run_block gate-selected-readfail "$GATE_CODE"
rc=$?
[ "$rc" != 0 ] && pass "exits $rc when the current policy cannot be read" || fail "read failure reported success"
grep -q '\[access\] \[app-1\]' "$LOG/hq" && fail "wrote the policy without reading it" || pass "no access write after a failed read"

echo "[8e] C.3 selected: a failed access write stops"
ORG_SLUG=acme APP_ID=app-1 SENSITIVE=true ACCESS_MODE=selected HQ_FAIL=access \
  SELECTED_USERS_JSON='[{"id":"person_a"}]' SELECTED_GROUPS_JSON='[]' \
  run_block gate-selected-writefail "$GATE_CODE"
rc=$?
[ "$rc" != 0 ] && grep -Fq 'earlier members may still have access' "$LOG/err" \
  && pass "exits $rc and warns that earlier members may keep access" || fail "write failure rc=$rc: $(cat "$LOG/err")"
unset ACCESS_STATE

echo "[9] C.3 private: hq deploy private-gate with one --email per pattern"
ORG_SLUG=acme APP_ID=app-1 SENSITIVE=true ACCESS_MODE=private ALLOW_PATTERNS=$'a@example.test\n*@example.org' \
  run_block gate-private "$GATE_CODE"
rc=$?
[ "$rc" = 0 ] || fail "private gate exited $rc: $(cat "$LOG/err")"
hq_called '[private-gate] [app-1] [--company] [acme] [--email] [a@example.test] [--email] [*@example.org] [--json]' \
  && pass "private-gate with both patterns" || fail "private-gate argv: $(cat "$LOG/hq" 2>/dev/null)"
no_direct gate-private && pass "no direct /access-mode or /allowed-emails"

echo "[10] Static upload: hq deploy upload; DEPLOY_ID and LIVE_URL from its output"
ORG_SLUG=acme APP_ID=app-1 run_block upload "$STATIC_CODE"
# The block's last line is `[ -n "$KEEP_OUT" ] && rm -rf ...`, so its exit
# status is 1 when KEEP_OUT is empty; success is UPLOAD_OK and a clean stderr.
[ ! -s "$LOG/err" ] || fail "static upload wrote errors: $(cat "$LOG/err")"
hq_called "[upload] [report] [$TMP/log-upload/site.tar.gz] [--company] [acme] [--manifest-org] [--json]" \
  && pass "upload report <tarball> --company acme --manifest-org --json" || fail "upload argv: $(cat "$LOG/hq" 2>/dev/null)"
[ "$(var DEPLOY_ID)" = dep-9 ] && [ "$(var LIVE_URL)" = https://report.example.test ] && [ "$(var UPLOAD_OK)" = true ] \
  && pass "DEPLOY_ID, LIVE_URL and UPLOAD_OK set" || fail "vars: $(tr '\n' ' ' <"$LOG/vars")"
grep -Fq -- '--deploy-id dep-9' "$LOG/scripts" && pass "route-host record gets the deploy id" || fail "route-host: $(cat "$LOG/scripts" 2>/dev/null)"
no_direct upload && pass "no direct /api/deploys or presigned PUT"

echo "[11] Static upload: a failed upload stops before the record"
ORG_SLUG=acme APP_ID=app-1 HQ_FAIL=upload run_block upload-fail "$STATIC_CODE"
rc=$?
[ "$rc" != 0 ] && [ -z "$(var UPLOAD_OK)" ] && pass "exits $rc, UPLOAD_OK unset" || fail "upload failure rc=$rc UPLOAD_OK=$(var UPLOAD_OK)"
[ ! -s "$LOG/scripts" ] && pass "no route-host record" || fail "recorded after a failed upload"

echo "[12] Verify: a proven password gate reads state through hq deploy inspect"
ORG_SLUG=acme APP_ID=app-1 SENSITIVE=true ACCESS_MODE=password LIVE_URL=https://report.example.test \
  STATE_MODE=password STATE_PROTECTED=true run_block verify-ok "$VERIFY_CODE"
rc=$?
[ "$rc" = 0 ] || fail "verify exited $rc: $(cat "$LOG/err")"
hq_called '[inspect] [app-1] [--company] [acme] [--json]' && pass "inspect app-1 --company acme" || fail "inspect argv: $(cat "$LOG/hq" 2>/dev/null)"
hq_called '[takedown]' && fail "took a proven app down" || pass "no takedown"
no_direct verify-ok && pass "no direct GET /api/apps/:id"

echo "[13] Verify: a company gate is read through hq deploy access get"
ORG_SLUG=acme APP_ID=app-1 SENSITIVE=true ACCESS_MODE=company COMPANY_UID=cmp_1 LIVE_URL=https://report.example.test \
  STATE_MODE=company run_block verify-company "$VERIFY_CODE"
rc=$?
[ "$rc" = 0 ] || fail "company verify exited $rc: $(cat "$LOG/err")"
hq_called '[access] [get] [app-1] [--company] [acme] [--json]' && pass "access get app-1 --company acme" || fail "access get argv: $(cat "$LOG/hq" 2>/dev/null)"
no_direct verify-company && pass "no direct GET /access-policy"

echo "[14] Verify: a company policy with another company id is not proven"
ORG_SLUG=acme APP_ID=app-1 SENSITIVE=true ACCESS_MODE=company COMPANY_UID=cmp_1 LIVE_URL=https://report.example.test \
  STATE_MODE=company POLICY_UID=cmp_other run_block verify-company-mismatch "$VERIFY_CODE"
rc=$?
[ "$rc" != 0 ] && hq_called '[takedown] [app-1] [--company] [acme] [--json]' \
  && pass "mismatched company id: taken down, exits $rc" || fail "mismatch rc=$rc hq: $(cat "$LOG/hq" 2>/dev/null)"

echo "[15] Verify: an unproven gate is taken down through hq deploy takedown"
DEPLOY_SCOPE=personal APP_ID=app-1 SENSITIVE=true ACCESS_MODE=password LIVE_URL=https://report.example.test \
  STATE_MODE=public STATE_PROTECTED=false EDGE_CODE=200 run_block verify-fail "$VERIFY_CODE"
rc=$?
[ "$rc" != 0 ] && pass "exits $rc" || fail "unproven gate did not fail"
hq_called '[takedown] [app-1] [--personal] [--json]' && pass "takedown app-1 --personal" || fail "takedown argv: $(cat "$LOG/hq" 2>/dev/null)"
grep -Fq 'taken down (inactive)' "$LOG/err" && pass "reports the takedown" || fail "no takedown report: $(cat "$LOG/err")"
no_direct verify-fail && pass "no direct PATCH /api/apps/:id"

echo "[16] Verify: a failed takedown says the app may be public"
DEPLOY_SCOPE=personal APP_ID=app-1 SENSITIVE=true ACCESS_MODE=password LIVE_URL=https://report.example.test \
  STATE_PROTECTED=false EDGE_CODE=200 HQ_FAIL=takedown run_block verify-takedown-fail "$VERIFY_CODE"
rc=$?
[ "$rc" != 0 ] && grep -Fq 'TAKEDOWN FAILED' "$LOG/err" && pass "exits $rc and warns" || fail "takedown failure rc=$rc: $(cat "$LOG/err")"

echo "[17] No hq on PATH: nothing runs"
LOG="$TMP/log-nohq"; mkdir -p "$LOG"
out="$(cd "$TMP/work" && PATH="/usr/bin:/bin" HELPER_CODE="$HELPER_CODE" bash -c 'DEPLOY_SCOPE=company ORG_SLUG=acme API=x; eval "$HELPER_CODE"; echo reached' 2>&1)"
rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -F >/dev/null hq_cli_missing && ! printf '%s' "$out" | grep -F >/dev/null reached \
  && pass "hq_cli_missing, exits $rc" || fail "missing hq did not stop: rc=$rc $out"

grep -Fq 'Bash(hq deploy:*)' "$SKILL" && pass "allowed-tools permits hq deploy" || fail "allowed-tools lacks Bash(hq deploy:*)"

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: deploy-skill-hq-cli ($FAILS)" >&2
  exit 1
fi
echo "ALL PASS: deploy-skill-hq-cli"
