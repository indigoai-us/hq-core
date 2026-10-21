#!/usr/bin/env bash
# Regression: project-summary deploys must never leave content public.
#
# 2026-10-18: GET /api/apps is paginated (nextCursor) and the org had 1,300+
# apps. deploy-summary.sh read only page one, uploaded the tarball (content
# live), then failed the post-upload APP_ID lookup with app_id_unresolved and
# exited before applying the gate. Two internal pages were public for minutes.
#
# This suite drives the real script against a mocked hq-deploy API and checks:
#   - the app is found on any page, or created with the id from the create
#     response (no second lookup)
#   - the gate is applied and proven BEFORE any upload, in call order
#   - if no gate can be proven, nothing is uploaded
#   - if the gate cannot be proven on the live URL after upload, the app is
#     taken down (PATCH active:false) and no MODE is reported
#   - a failed app list fails closed (never treated as "not found")
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SRC="$ROOT/.claude/skills/project-summary/scripts/deploy-summary.sh"
DEPLOY_SRC="$ROOT/.claude/skills/deploy/scripts"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$SRC" ] || fail "deploy-summary.sh not found at $SRC"
[ -f "$DEPLOY_SRC/list-apps.sh" ] || fail "list-apps.sh not found at $DEPLOY_SRC"
command -v jq >/dev/null 2>&1 || fail "needs jq"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

make_fixture() {
  local case_dir="$1"
  mkdir -p "$case_dir/.claude/skills/project-summary/scripts" \
    "$case_dir/.claude/skills/deploy/scripts" "$case_dir/bin" \
    "$case_dir/build" "$case_dir/companies" "$case_dir/pages"
  cp "$SRC" "$case_dir/.claude/skills/project-summary/scripts/deploy-summary.sh"
  cp "$DEPLOY_SRC/list-apps.sh" "$DEPLOY_SRC/deploy-api-request.sh" "$case_dir/.claude/skills/deploy/scripts/"
  printf '<!doctype html>\n' > "$case_dir/build/index.html"
  printf 'companies:\n  acme:\n    cloud_uid: cmp_acme\n' > "$case_dir/companies/manifest.yaml"
  : > "$case_dir/calls"
  cat > "$case_dir/.claude/skills/deploy/scripts/identity-resolve.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"status":"ok","jwt":"test-jwt"}'
EOF
  cat > "$case_dir/.claude/skills/deploy/scripts/guardrails-check.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"pass":true,"tarball_path":"$case_dir/archive.tar.gz","size_bytes":1,"sha256":"test-sha"}'
EOF
  printf 'x' > "$case_dir/archive.tar.gz"
  cat > "$case_dir/.claude/skills/deploy/scripts/password-helper.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  gen) printf '%s\n' 'test-password' ;;
  announce) exit 0 ;;
esac
EOF
  chmod +x "$case_dir/.claude/skills/deploy/scripts/"*.sh
  # One page by default: the app exists on it.
  printf '%s\n' '{"apps":[{"name":"summary","subdomain":"summary","id":"app-1","url":"http://live.test"}],"nextCursor":null}' \
    > "$case_dir/pages/first.json"

  # Mock curl. Honors -X, -o, -w; logs "METHOD URL" for order assertions.
  # Server state lives in marker files under $MOCK_DIR.
  cat > "$case_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
url="" method="" out="" wfmt="" auth=0 args=("$@")
for ((i=0; i < ${#args[@]}; i++)); do
  a="${args[$i]}"
  case "$a" in
    -X) method="${args[$((i+1))]}" ;;
    -o) out="${args[$((i+1))]}" ;;
    -w) wfmt="${args[$((i+1))]}" ;;
    *Authorization:*) auth=1 ;;
    http://*|https://*) url="$a" ;;
  esac
done
[ -n "$method" ] || method=GET
printf '%s %s\n' "$method" "$url" >> "$MOCK_DIR/calls"
next_value() {
  local name="$1" count_file="$MOCK_DIR/$1.count" values="$MOCK_DIR/$1.values" n value
  n=0; [ -f "$count_file" ] && n="$(cat "$count_file")"
  n=$((n + 1)); printf '%s' "$n" > "$count_file"
  value="$(sed -n "${n}p" "$values" 2>/dev/null || true)"
  [ -n "$value" ] || value="$(tail -n 1 "$values")"
  printf '%s' "$value"
}
gated() { [ -f "$MOCK_DIR/company_set" ] || [ -f "$MOCK_DIR/password_set" ]; }
body="" status=200
case "$method $url" in
  "GET http://api.test/api/apps")
    # Unpaginated request: the real API returns only the first page.
    body="$(cat "$MOCK_DIR/pages/first.json")" ;;
  "GET http://api.test/api/apps?limit=100"*)
    cursor=first
    case "$url" in *"&cursor="*) cursor="${url##*&cursor=}" ;; esac
    if [ -n "${LIST_FAIL_CURSOR:-}" ] && [ "$cursor" = "$LIST_FAIL_CURSOR" ]; then
      status=500; body='{"error":{"code":"INTERNAL","message":"boom"}}'
    else
      body="$(cat "$MOCK_DIR/pages/$cursor.json")"
    fi ;;
  "POST http://api.test/api/apps")
    if cat "$MOCK_DIR"/pages/*.json | jq -e -s 'any(.[].apps[]; .name == "summary")' >/dev/null; then
      # The real API refuses a second app with the same subdomain.
      status=409; body='{"error":{"code":"SUBDOMAIN_DUPLICATE"}}'
    else
      status=201; body='{"id":"app-1","subdomain":"summary","url":"http://live.test"}'
      touch "$MOCK_DIR/created"
      # Like the real API (UUID sort order), the new app lands on a later
      # page, not necessarily the first one.
      last="$(grep -l '"nextCursor":null' "$MOCK_DIR"/pages/*.json | head -1)"
      jq -c '.apps += [{"name":"summary","subdomain":"summary","id":"app-1","url":"http://live.test"}]' "$last" > "$last.tmp" \
        && mv "$last.tmp" "$last"
    fi ;;
  "PUT http://api.test/api/apps/app-1/access-policy")
    status="$PUT_STATUS"; [[ "$status" == 2* ]] && touch "$MOCK_DIR/company_set" ;;
  "GET http://api.test/api/apps/app-1/access-policy")
    if [ -f "$MOCK_DIR/company_set" ]; then body='{"mode":"company","companyUid":"cmp_acme"}'
    else body='{"mode":"public","companyUid":""}'; fi ;;
  "POST http://api.test/api/apps/app-1/access-mode")
    status="$PASSWORD_STATUS"
    if [[ "$status" == 2* ]]; then rm -f "$MOCK_DIR/company_set"; touch "$MOCK_DIR/password_set"; fi ;;
  "GET http://api.test/api/apps/app-1")
    [ "$auth" = 1 ] || { echo 'state reread was unauthenticated' >&2; exit 8; }
    if [ -n "${STATE_FORCE:-}" ]; then body="$STATE_FORCE"
    elif [ -f "$MOCK_DIR/company_set" ]; then body='{"accessMode":"company","passwordProtected":false,"accessPolicy":null}'
    elif [ -f "$MOCK_DIR/password_set" ]; then body='{"accessMode":"password","passwordProtected":true}'
    else body='{"accessMode":"public","passwordProtected":false}'; fi ;;
  "PATCH http://api.test/api/apps/app-1")
    status="${TAKEDOWN_STATUS:-200}"; [[ "$status" == 2* ]] && touch "$MOCK_DIR/taken_down" ;;
  "POST http://api.test/api/deploys")
    body='{"deployId":"deploy-1","presignedUrl":"http://upload.test/archive"}' ;;
  "PUT http://upload.test/archive")
    touch "$MOCK_DIR/uploaded" ;;
  "POST http://api.test/api/deploys/deploy-1/complete")
    touch "$MOCK_DIR/completed"; body='{"url":"http://live.test"}' ;;
  "GET http://live.test/")
    [ "$auth" = 0 ] || { echo 'edge verification was not anonymous' >&2; exit 8; }
    if [ -f "$MOCK_DIR/gate.values" ]; then status="$(next_value gate)"
    elif gated; then status=302
    else status=200; fi ;;
  *)
    echo "unexpected curl request: $method $url" >&2
    exit 9 ;;
esac
if [ -n "$out" ]; then
  [ "$out" = /dev/null ] || printf '%s' "$body" > "$out"
else
  printf '%s' "$body"
fi
[ -z "$wfmt" ] || printf '%s' "${wfmt//%\{http_code\}/$status}"
exit 0
EOF
  chmod +x "$case_dir/bin/curl"
}

# run_case <name> <expected_exit> [ENV=VALUE ...]
run_case() {
  local name="$1" expected_code="$2" case_dir="$TMP/$1" out code
  shift 2
  [ -d "$case_dir" ] || make_fixture "$case_dir"
  set +e
  out="$(env PATH="$case_dir/bin:$PATH" MOCK_DIR="$case_dir" PUT_STATUS=204 PASSWORD_STATUS=200 \
    HQ_DEPLOY_API='http://api.test' HQ_DEPLOY_GATE_ATTEMPTS=3 HQ_DEPLOY_GATE_SLEEP_SECS=0 HOME="$case_dir" "$@" \
    bash "$case_dir/.claude/skills/project-summary/scripts/deploy-summary.sh" \
    "$case_dir/build" summary acme 2>&1)"
  code=$?
  set -e
  [ "$code" -eq "$expected_code" ] || fail "$name exit=$code, expected $expected_code: $out"
  CASE_OUT="$out"
  CASE_DIR="$case_dir"
}

line_of() { grep -n -F -- "$2" "$1/calls" | head -1 | cut -d: -f1; }
assert_before() {
  local dir="$1" first="$2" second="$3" a b
  a="$(line_of "$dir" "$first")"; b="$(line_of "$dir" "$second")"
  [ -n "$a" ] || fail "missing call: $first"
  [ -n "$b" ] || fail "missing call: $second"
  [ "$a" -lt "$b" ] || fail "'$first' (call $a) must come before '$second' (call $b)"
}
assert_no_upload() {
  [ ! -f "$1/uploaded" ] || fail "content was uploaded: $(cat "$1/calls")"
  [ ! -f "$1/completed" ] || fail "deploy was completed"
}
assert_no_mode() {
  printf '%s' "$CASE_OUT" | grep -q '^MODE=' && fail "a gate mode was reported: $CASE_OUT"
  return 0
}

echo "[1] app on page 2 of a paginated list is found; gate is set before upload"
make_fixture "$TMP/page2"
jq -nc '{apps: [range(0;100) | {name: "other-\(.)", subdomain: "other-\(.)", id: "other-\(.)"}], nextCursor: "cur2"}' \
  > "$TMP/page2/pages/first.json"
printf '%s\n' '{"apps":[{"name":"summary","subdomain":"summary","id":"app-1","url":"http://live.test"}],"nextCursor":"cur3"}' \
  > "$TMP/page2/pages/cur2.json"
printf '%s\n' '{"apps":[],"nextCursor":null}' > "$TMP/page2/pages/cur3.json"
run_case page2 0
printf '%s' "$CASE_OUT" | grep -q '^MODE=company$' || fail "expected company mode: $CASE_OUT"
printf '%s' "$CASE_OUT" | grep -q '^GATE=302$' || fail "expected GATE=302: $CASE_OUT"
grep -qF 'GET http://api.test/api/apps?limit=100&cursor=cur2' "$CASE_DIR/calls" || fail "page 2 was not requested"
grep -qF 'cursor=cur3' "$CASE_DIR/calls" && fail "kept paging after the app was found"
[ ! -f "$CASE_DIR/created" ] || fail "created a duplicate app although it exists on page 2"
assert_before "$CASE_DIR" 'PUT http://api.test/api/apps/app-1/access-policy' 'PUT http://upload.test/archive'
assert_before "$CASE_DIR" 'GET http://live.test/' 'PUT http://upload.test/archive'
pass "paginated lookup succeeds and the gate precedes the upload"

echo "[2] app on no page is created and the create response id is used"
make_fixture "$TMP/create"
jq -nc '{apps: [range(0;100) | {name: "other-\(.)", subdomain: "other-\(.)", id: "other-\(.)"}], nextCursor: "cur2"}' \
  > "$TMP/create/pages/first.json"
printf '%s\n' '{"apps":[{"name":"else","subdomain":"else","id":"x"}],"nextCursor":null}' > "$TMP/create/pages/cur2.json"
run_case create 0
printf '%s' "$CASE_OUT" | grep -q '^MODE=company$' || fail "expected company mode: $CASE_OUT"
[ -f "$CASE_DIR/created" ] || fail "app was not created"
[ "$(grep -c 'GET http://api.test/api/apps?' "$CASE_DIR/calls")" = 2 ] || fail "expected exactly one full list pass (2 pages)"
assert_before "$CASE_DIR" 'POST http://api.test/api/apps' 'PUT http://api.test/api/apps/app-1/access-policy'
assert_before "$CASE_DIR" 'PUT http://api.test/api/apps/app-1/access-policy' 'PUT http://upload.test/archive'
pass "new app is gated by id from the create response, before upload"

echo "[3] a failed list page fails closed: no create, no upload"
make_fixture "$TMP/list-fail"
printf '%s\n' '{"apps":[],"nextCursor":"cur2"}' > "$TMP/list-fail/pages/first.json"
run_case list-fail 1 LIST_FAIL_CURSOR=cur2
printf '%s' "$CASE_OUT" | grep -q 'ERR: app_list_failed' || fail "missing app_list_failed: $CASE_OUT"
[ ! -f "$CASE_DIR/created" ] || fail "a list failure was treated as 'not found'"
assert_no_upload "$CASE_DIR"; assert_no_mode
pass "list failure is not 'not found'"

echo "[4] company PUT 400 falls back to a password gate, still before upload"
run_case put-400 0 PUT_STATUS=400
printf '%s' "$CASE_OUT" | grep -q '^MODE=password$' || fail "PUT 400 did not use password fallback: $CASE_OUT"
printf '%s' "$CASE_OUT" | grep -q '^PASSWORD=test-password$' || fail "password not reported: $CASE_OUT"
assert_before "$CASE_DIR" 'POST http://api.test/api/apps/app-1/access-mode' 'PUT http://upload.test/archive'
pass "password fallback is applied before upload"

echo "[5] gate failure before upload: nothing is uploaded"
run_case gate-fail 1 PUT_STATUS=400 PASSWORD_STATUS=400
printf '%s' "$CASE_OUT" | grep -q 'ERR: access_gate_unverified (nothing uploaded)' || fail "missing fail-closed error: $CASE_OUT"
assert_no_upload "$CASE_DIR"; assert_no_mode
grep -qF 'POST http://api.test/api/deploys' "$CASE_DIR/calls" && fail "a deploy was initiated without a gate"
pass "no gate -> no upload"

echo "[6] API state never reflects the gate (stale): nothing is uploaded"
run_case stale-state 1 STATE_FORCE='{"accessMode":"public","passwordProtected":false}'
assert_no_upload "$CASE_DIR"; assert_no_mode
pass "stale state is not trusted"

echo "[7] existing app whose edge still serves it publicly: nothing is uploaded"
make_fixture "$TMP/edge-stale"
printf '200\n' > "$TMP/edge-stale/gate.values"
run_case edge-stale 1
printf '%s' "$CASE_OUT" | grep -q 'ERR: access_gate_not_at_edge' || fail "missing edge error: $CASE_OUT"
assert_no_upload "$CASE_DIR"; assert_no_mode
pass "upload waits for the edge to redirect"

echo "[8] gate unproven on the live URL after upload: app is taken down"
make_fixture "$TMP/post-fail"
printf '%s\n' '{"apps":[],"nextCursor":null}' > "$TMP/post-fail/pages/first.json"
printf '200\n' > "$TMP/post-fail/gate.values"
run_case post-fail 1
[ -f "$CASE_DIR/uploaded" ] || fail "fixture should reach upload (new app, no pre-upload edge check)"
[ -f "$CASE_DIR/taken_down" ] || fail "app was not taken down: $(cat "$CASE_DIR/calls")"
assert_before "$CASE_DIR" 'POST http://api.test/api/deploys/deploy-1/complete' 'PATCH http://api.test/api/apps/app-1'
printf '%s' "$CASE_OUT" | grep -q 'ERR: access_gate_unverified_after_upload; app taken down' || fail "missing takedown error: $CASE_OUT"
assert_no_mode
pass "unproven live gate -> takedown, nothing reported as gated"

echo "[9] takedown itself fails: loud error, non-zero exit"
make_fixture "$TMP/takedown-fail"
printf '%s\n' '{"apps":[],"nextCursor":null}' > "$TMP/takedown-fail/pages/first.json"
printf '200\n' > "$TMP/takedown-fail/gate.values"
run_case takedown-fail 1 TAKEDOWN_STATUS=500
printf '%s' "$CASE_OUT" | grep -q 'TAKEDOWN FAILED' || fail "takedown failure not surfaced: $CASE_OUT"
assert_no_mode
pass "takedown failure is surfaced"

echo "[10] edge propagation after upload retries until 302"
make_fixture "$TMP/propagation"
printf '%s\n' '{"apps":[],"nextCursor":null}' > "$TMP/propagation/pages/first.json"
printf '200\n302\n' > "$TMP/propagation/gate.values"
run_case propagation 0
printf '%s' "$CASE_OUT" | grep -q '^MODE=company$' || fail "propagated company gate was not accepted: $CASE_OUT"
[ "$(cat "$CASE_DIR/gate.count")" = 2 ] || fail "expected a retry after anonymous edge response 200"
[ ! -f "$CASE_DIR/taken_down" ] || fail "took down a gated app"
pass "post-upload verify waits for edge propagation"

echo "ALL PASS: deploy-summary-gating"
