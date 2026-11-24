#!/usr/bin/env bash
# Regression: project-summary deploys must never leave content public.
#
# 2026-10-18: GET /api/apps is paginated (nextCursor) and the org had 1,300+
# apps. deploy-summary.sh read only page one, uploaded the tarball (content
# live), then failed the post-upload APP_ID lookup with app_id_unresolved and
# exited before applying the gate. Two internal pages were public for minutes.
#
# This suite drives the real script against a mocked hq CLI that holds the
# hq-deploy state (US-033: every hq-deploy call goes through `hq deploy`) and
# a mocked curl that answers only the anonymous edge probe. It checks:
#   - no hq-deploy API request is made outside the hq CLI (no curl copy)
#   - the app is found on any page, or created with the id from the create
#     response (no second lookup); only the exact app name is used
#   - every hq deploy call names the company (--company) for a company deck,
#     or the personal scope (--personal) otherwise, on the resolved API base
#   - the gate is applied and proven BEFORE any upload, in call order
#   - the password reaches the CLI only through a file that is removed after
#   - if no gate can be proven, nothing is uploaded
#   - if the gate cannot be proven on the live URL after upload, the app is
#     taken down (hq deploy takedown) and no MODE is reported
#   - a failed app list fails closed (never treated as "not found")
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SRC="$ROOT/.claude/skills/project-summary/scripts/deploy-summary.sh"
DEPLOY_SRC="$ROOT/.claude/skills/deploy/scripts"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$SRC" ] || fail "deploy-summary.sh not found at $SRC"
command -v jq >/dev/null 2>&1 || fail "needs jq"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

make_fixture() {
  local case_dir="$1"
  mkdir -p "$case_dir/.claude/skills/project-summary/scripts" \
    "$case_dir/.claude/skills/deploy/scripts" "$case_dir/bin" \
    "$case_dir/build" "$case_dir/companies" "$case_dir/pages" "$case_dir/tmp"
  cp "$SRC" "$case_dir/.claude/skills/project-summary/scripts/deploy-summary.sh"
  printf '<!doctype html>\n' > "$case_dir/build/index.html"
  printf 'companies:\n  acme:\n    cloud_uid: cmp_acme\n' > "$case_dir/companies/manifest.yaml"
  : > "$case_dir/calls"
  : > "$case_dir/hq-calls"
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

  # Mock curl: only the anonymous edge probe of the live URL is expected.
  # Any other request is a direct hq-deploy call the CLI should have made.
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
    *Authorization:*|*X-Org-Slug:*|*X-HQ-Deploy-Scope:*) auth=1 ;;
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
case "$method $url" in
  "GET http://live.test/")
    [ "$auth" = 0 ] || { echo 'edge verification was not anonymous' >&2; exit 8; }
    if [ -f "$MOCK_DIR/gate.values" ]; then status="$(next_value gate)"
    elif gated; then status=302
    else status=200; fi ;;
  *)
    printf '%s %s\n' "$method" "$url" >> "$MOCK_DIR/direct-api"
    echo "unexpected curl request: $method $url" >&2
    exit 9 ;;
esac
[ -z "$out" ] || [ "$out" = /dev/null ] || : > "$out"
[ -z "$wfmt" ] || printf '%s' "${wfmt//%\{http_code\}/$status}"
exit 0
EOF
  chmod +x "$case_dir/bin/curl"

  # Mock hq CLI holding the hq-deploy state in marker files under $MOCK_DIR.
  # The real CLI reads every list page itself, so `list` returns the apps of
  # every page file. Each call is logged as "HQ <subcommand> <target> <mode>"
  # to calls and, with its scope and API base, to hq-calls; the full argv goes
  # to hq-argv.
  cat > "$case_dir/bin/hq" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
[ "${1:-}" = deploy ] || { echo "unexpected hq command: $*" >&2; exit 9; }
shift
printf '%s\n' "$*" >> "$MOCK_DIR/hq-argv"
company="" personal=0 json=0 mode="" yes=0 type="" pwfile="" positional=()
sub="$1"; shift
if [ "$sub" = access ] && [ "${1:-}" = get ]; then sub="access-get"; shift; fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --company) company="$2"; shift 2 ;;
    --personal) personal=1; shift ;;
    --mode) mode="$2"; shift 2 ;;
    --type) type="$2"; shift 2 ;;
    --password-file) pwfile="$2"; shift 2 ;;
    --json) json=1; shift ;;
    --yes) yes=1; shift ;;
    -*) echo "unexpected hq flag: $1" >&2; exit 9 ;;
    *) positional+=("$1"); shift ;;
  esac
done
target="${positional[0]:-}"
printf 'HQ %s %s %s\n' "$sub" "$target" "$mode" >> "$MOCK_DIR/calls"
printf '%s company=%s personal=%s api=%s json=%s yes=%s\n' "$sub" "$company" "$personal" "${HQ_DEPLOY_API_URL:-}" "$json" "$yes" >> "$MOCK_DIR/hq-calls"
# Like the real CLI: exactly one of --company / --personal on scoped calls.
if [ -n "$company" ] && [ "$personal" = 1 ]; then echo "Choose one of --company <slug> or --personal." >&2; exit 1; fi
case "$sub" in
  list)
    [ -z "${LIST_FAIL:-}" ] || { echo "Could not list deploy apps (HTTP 500, INTERNAL)." >&2; exit 1; }
    cat "$MOCK_DIR"/pages/*.json | jq -c -s --arg q "$target" --arg c "$company" \
      '{company: (if $c == "" then null else $c end), query: $q, apps: [.[].apps[] | select((.name // "") | ascii_downcase | contains($q | ascii_downcase))]}' ;;
  create)
    [ "$type" = static ] || { echo "unexpected app type: $type" >&2; exit 9; }
    if cat "$MOCK_DIR"/pages/*.json | jq -e -s --arg n "$target" 'any(.[].apps[]; .name == $n)' >/dev/null; then
      # The real API refuses a second app with the same subdomain.
      echo "hq-deploy rejected the operation (HTTP 409)." >&2; exit 1
    fi
    touch "$MOCK_DIR/created"
    printf '%s\n' '{"id":"app-1","name":"summary","subdomain":"summary","url":"http://live.test"}' ;;
  inspect)
    [ "$target" = app-1 ] || { echo "inspect of unknown app $target" >&2; exit 9; }
    if [ -n "${STATE_FORCE:-}" ]; then printf '%s\n' "$STATE_FORCE"
    elif [ -f "$MOCK_DIR/company_set" ]; then printf '%s\n' '{"id":"app-1","accessMode":"company","passwordProtected":false}'
    elif [ -f "$MOCK_DIR/password_set" ]; then printf '%s\n' '{"id":"app-1","accessMode":"password","passwordProtected":true}'
    else printf '%s\n' '{"id":"app-1","accessMode":"public","passwordProtected":false}'; fi ;;
  access)
    [ "$mode" = company ] || { echo "unexpected access mode: $mode" >&2; exit 9; }
    if [[ "$PUT_STATUS" == 2* ]]; then
      touch "$MOCK_DIR/company_set"
      jq -nc --arg a "$target" --arg c "$company" '{company: $c, app: $a, policy: {mode: "company", companyUid: "cmp_acme", users: [], groups: []}}'
    else
      echo "hq-deploy refused the change: company mismatch (ACCESS_POLICY_COMPANY_MISMATCH)" >&2; exit 1
    fi ;;
  access-get)
    if [ -f "$MOCK_DIR/company_set" ]; then policy='{"mode":"company","companyUid":"cmp_acme"}'
    else policy='{"mode":"public","companyUid":null}'; fi
    jq -nc --arg a "$target" --arg c "$company" --argjson p "$policy" '{company: $c, app: $a, policy: $p}' ;;
  password-gate)
    [ -f "$pwfile" ] || { echo "Could not read the password file at $pwfile. Nothing was sent." >&2; exit 1; }
    cat "$pwfile" > "$MOCK_DIR/password-seen"
    printf '%s\n' "$pwfile" > "$MOCK_DIR/password-file-path"
    [[ "$PASSWORD_STATUS" == 2* ]] || { echo "hq-deploy rejected the operation (HTTP $PASSWORD_STATUS)." >&2; exit 1; }
    rm -f "$MOCK_DIR/company_set"; touch "$MOCK_DIR/password_set" ;;
  takedown)
    [[ "${TAKEDOWN_STATUS:-200}" == 2* ]] || { echo "hq-deploy rejected the operation (HTTP $TAKEDOWN_STATUS)." >&2; exit 1; }
    touch "$MOCK_DIR/taken_down" ;;
  upload)
    [ "$target" = summary ] || { echo "upload to unexpected app $target" >&2; exit 9; }
    [ -f "${positional[1]:-}" ] || { echo "Could not read the archive file. Nothing was sent." >&2; exit 1; }
    [ -z "${UPLOAD_FAIL:-}" ] || { echo "Archive upload failed (HTTP 403). Deployment was not completed." >&2; exit 1; }
    touch "$MOCK_DIR/uploaded" "$MOCK_DIR/completed"
    printf '%s\n' '{"url":"http://live.test"}' ;;
  *) echo "unexpected hq deploy subcommand: $sub" >&2; exit 9 ;;
esac
EOF
  chmod +x "$case_dir/bin/hq"
}

# run_case <name> <expected_exit> [ENV=VALUE ...]
run_case() {
  local name="$1" expected_code="$2" case_dir="$TMP/$1" out code
  shift 2
  [ -d "$case_dir" ] || make_fixture "$case_dir"
  set +e
  out="$(env PATH="$case_dir/bin:$PATH" MOCK_DIR="$case_dir" PUT_STATUS=204 PASSWORD_STATUS=200 \
    HQ_DEPLOY_API='http://api.test' HQ_DEPLOY_GATE_ATTEMPTS=3 HQ_DEPLOY_GATE_SLEEP_SECS=0 HOME="$case_dir" TMPDIR="$case_dir/tmp" "$@" \
    bash "$case_dir/.claude/skills/project-summary/scripts/deploy-summary.sh" \
    "$case_dir/build" summary ${CASE_CO-acme} 2>&1)"
  code=$?
  set -e
  [ "$code" -eq "$expected_code" ] || fail "$name exit=$code, expected $expected_code: $out"
  CASE_OUT="$out"
  CASE_DIR="$case_dir"
  # US-033: no hq-deploy API request outside the hq CLI, in any case.
  [ ! -s "$case_dir/direct-api" ] || fail "$name made hq-deploy requests outside the hq CLI: $(cat "$case_dir/direct-api")"
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
  printf '%s' "$CASE_OUT" | grep >/dev/null '^MODE=' && fail "a gate mode was reported: $CASE_OUT"
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
printf '%s' "$CASE_OUT" | grep >/dev/null '^MODE=company$' || fail "expected company mode: $CASE_OUT"
printf '%s' "$CASE_OUT" | grep >/dev/null '^GATE=302$' || fail "expected GATE=302: $CASE_OUT"
[ "$(grep -c '^HQ list summary' "$CASE_DIR/calls")" = 1 ] || fail "expected one hq deploy list call: $(cat "$CASE_DIR/calls")"
[ ! -f "$CASE_DIR/created" ] || fail "created a duplicate app although it exists on page 2"
assert_before "$CASE_DIR" 'HQ access app-1 company' 'HQ upload summary'
assert_before "$CASE_DIR" 'HQ access-get app-1' 'HQ upload summary'
assert_before "$CASE_DIR" 'HQ inspect app-1' 'HQ upload summary'
assert_before "$CASE_DIR" 'GET http://live.test/' 'HQ upload summary'
pass "paginated lookup succeeds and the gate precedes the upload"

echo "[2] app on no page is created and the create response id is used"
make_fixture "$TMP/create"
jq -nc '{apps: [range(0;100) | {name: "other-\(.)", subdomain: "other-\(.)", id: "other-\(.)"}], nextCursor: "cur2"}' \
  > "$TMP/create/pages/first.json"
printf '%s\n' '{"apps":[{"name":"else","subdomain":"else","id":"x"}],"nextCursor":null}' > "$TMP/create/pages/cur2.json"
run_case create 0
printf '%s' "$CASE_OUT" | grep >/dev/null '^MODE=company$' || fail "expected company mode: $CASE_OUT"
[ -f "$CASE_DIR/created" ] || fail "app was not created"
[ "$(grep -c '^HQ list summary' "$CASE_DIR/calls")" = 1 ] || fail "expected exactly one hq deploy list call"
[ "$(grep -c '^HQ create summary' "$CASE_DIR/calls")" = 1 ] || fail "expected one hq deploy create call: $(cat "$CASE_DIR/calls")"
grep -q '^create .* json=1 ' "$CASE_DIR/hq-calls" || fail "hq deploy create did not pass --json"
assert_before "$CASE_DIR" 'HQ create summary' 'HQ access app-1 company'
assert_before "$CASE_DIR" 'HQ access app-1 company' 'HQ upload summary'
pass "new app is gated by id from the create response, before upload"

echo "[2b] hq deploy list matches by substring: only the exact app name is used"
make_fixture "$TMP/exact-name"
printf '%s\n' '{"apps":[{"name":"summary-old","subdomain":"summary-old","id":"app-old","url":"http://old.test"}],"nextCursor":null}' \
  > "$TMP/exact-name/pages/first.json"
run_case exact-name 0
[ -f "$CASE_DIR/created" ] || fail "a substring match was taken for the app: $(cat "$CASE_DIR/calls")"
grep -qF 'app-old' "$CASE_DIR/calls" && fail "the substring match app-old was used: $(cat "$CASE_DIR/calls")"
pass "a name that only contains the app name is not the app"

echo "[2c] a deck without the hq CLI fails before any call (company and personal)"
make_fixture "$TMP/no-hq"
rm "$TMP/no-hq/bin/hq"
mkdir -p "$TMP/no-hq/tools"
for tool in jq bash; do ln -s "$(command -v "$tool")" "$TMP/no-hq/tools/$tool"; done
run_case no-hq 1 PATH="$TMP/no-hq/bin:$TMP/no-hq/tools:/usr/bin:/bin"
printf '%s' "$CASE_OUT" | grep >/dev/null 'ERR: hq_cli_missing' || fail "missing hq did not fail closed: $CASE_OUT"
[ ! -s "$CASE_DIR/calls" ] || fail "API was called without the hq CLI: $(cat "$CASE_DIR/calls")"
assert_no_upload "$CASE_DIR"; assert_no_mode
make_fixture "$TMP/no-hq-personal"
rm "$TMP/no-hq-personal/bin/hq"
CASE_CO="" run_case no-hq-personal 1 PATH="$TMP/no-hq/bin:$TMP/no-hq/tools:/usr/bin:/bin"
printf '%s' "$CASE_OUT" | grep >/dev/null 'ERR: hq_cli_missing' || fail "missing hq did not fail closed for a personal deck: $CASE_OUT"
[ ! -s "$CASE_DIR/calls" ] || fail "a call was made without the hq CLI: $(cat "$CASE_DIR/calls")"
assert_no_upload "$CASE_DIR"; assert_no_mode
pass "no hq CLI -> no deploy"

echo "[3] a failed list fails closed: no create, no upload"
make_fixture "$TMP/list-fail"
printf '%s\n' '{"apps":[],"nextCursor":"cur2"}' > "$TMP/list-fail/pages/first.json"
run_case list-fail 1 LIST_FAIL=1
printf '%s' "$CASE_OUT" | grep >/dev/null 'ERR: app_list_failed' || fail "missing app_list_failed: $CASE_OUT"
[ ! -f "$CASE_DIR/created" ] || fail "a list failure was treated as 'not found'"
assert_no_upload "$CASE_DIR"; assert_no_mode
pass "list failure is not 'not found'"

echo "[4] company PUT 400 (wrong org) fails closed: no password fallback, nothing uploaded"
# feedback a9fdc51c: the company PUT returned 400 ACCESS_POLICY_COMPANY_MISMATCH
# and the script put a company deck behind a password gate in another org.
run_case put-400 1 PUT_STATUS=400
printf '%s' "$CASE_OUT" | grep >/dev/null 'ERR: company_gate_unverified (nothing uploaded; a company deck never falls back to a password gate)' \
  || fail "PUT 400 did not fail closed: $CASE_OUT"
grep -qF 'HQ access app-1 company' "$CASE_DIR/calls" || fail "the company gate was not requested through hq deploy access"
grep -qF 'HQ password-gate' "$CASE_DIR/calls" && fail "a password gate was set on a company deck"
printf '%s' "$CASE_OUT" | grep >/dev/null '^PASSWORD=' && fail "a password was reported for a company deck: $CASE_OUT"
assert_no_upload "$CASE_DIR"; assert_no_mode
pass "company gate failure fails closed without a password fallback"

echo "[4b] every hq deploy call of a company deck names the company on the resolved API"
make_fixture "$TMP/org-header"
printf '%s\n' '{"apps":[],"nextCursor":null}' > "$TMP/org-header/pages/first.json"
run_case org-header 0
printf '%s' "$CASE_OUT" | grep >/dev/null '^MODE=company$' || fail "expected company mode: $CASE_OUT"
hq_calls="$(grep -c . "$CASE_DIR/hq-calls")"
for sub in list create inspect access access-get upload; do
  grep -q "^$sub " "$CASE_DIR/hq-calls" || fail "no hq deploy $sub call: $(cat "$CASE_DIR/hq-calls")"
done
bad_hq="$(grep -v ' company=acme personal=0 api=http://api.test ' "$CASE_DIR/hq-calls" || true)"
[ -z "$bad_hq" ] || fail "hq deploy calls without --company acme on the resolved API: $bad_hq"
grep -q '^access company=acme .* json=1 yes=1$' "$CASE_DIR/hq-calls" || fail "the gate write did not pass --json --yes: $(cat "$CASE_DIR/hq-calls")"
pass "all $hq_calls hq deploy calls name acme on http://api.test; no direct API call"

echo "[4c] company slug with no cloud_uid fails closed before any API call"
make_fixture "$TMP/no-uid"
printf 'companies:\n  acme:\n    name: Acme\n' > "$TMP/no-uid/companies/manifest.yaml"
run_case no-uid 1
printf '%s' "$CASE_OUT" | grep >/dev/null 'ERR: company_uid_unresolved:acme' || fail "missing cloud_uid did not fail closed: $CASE_OUT"
[ ! -s "$CASE_DIR/calls" ] || fail "API was called for an unresolved company: $(cat "$CASE_DIR/calls")"
assert_no_mode
pass "unresolved company never deploys"

echo "[5] gate failure before upload: nothing is uploaded"
run_case gate-fail 1 PUT_STATUS=400 PASSWORD_STATUS=400
printf '%s' "$CASE_OUT" | grep >/dev/null 'ERR: company_gate_unverified (nothing uploaded' || fail "missing fail-closed error: $CASE_OUT"
assert_no_upload "$CASE_DIR"; assert_no_mode
grep -qF 'HQ upload' "$CASE_DIR/calls" && fail "a deploy was initiated without a gate"
pass "no gate -> no upload"

echo "[5b] personal deck: every call uses --personal; password gate (from a file) before upload"
make_fixture "$TMP/personal"
printf '%s\n' '{"apps":[],"nextCursor":null}' > "$TMP/personal/pages/first.json"
CASE_CO="" run_case personal 0
printf '%s' "$CASE_OUT" | grep >/dev/null '^MODE=password$' || fail "personal deck did not use a password gate: $CASE_OUT"
printf '%s' "$CASE_OUT" | grep >/dev/null '^PASSWORD=test-password$' || fail "personal deck did not report its password: $CASE_OUT"
assert_before "$CASE_DIR" 'HQ list summary' 'HQ create summary'
assert_before "$CASE_DIR" 'HQ password-gate app-1' 'HQ upload summary'
assert_before "$CASE_DIR" 'HQ inspect app-1' 'HQ upload summary'
bad_hq="$(grep -v ' company= personal=1 api=http://api.test ' "$CASE_DIR/hq-calls" || true)"
[ -z "$bad_hq" ] || fail "personal hq deploy calls without --personal (or with a company): $bad_hq"
grep -q '^access' "$CASE_DIR/hq-calls" && fail "a personal deck set a company gate"
[ "$(cat "$CASE_DIR/password-seen")" = test-password ] || fail "the CLI did not get the password through --password-file"
grep -qF 'test-password' "$CASE_DIR/hq-argv" && fail "the password was passed as a command argument: $(cat "$CASE_DIR/hq-argv")"
[ ! -e "$(cat "$CASE_DIR/password-file-path")" ] || fail "the password file was left on disk"
pass "personal deck: --personal on every call, password only via a removed file"

echo "[5c] personal deck whose password gate fails: nothing is uploaded"
CASE_CO="" run_case personal-gate-fail 1 PASSWORD_STATUS=400
printf '%s' "$CASE_OUT" | grep >/dev/null 'ERR: access_gate_unverified (nothing uploaded)' || fail "missing fail-closed error: $CASE_OUT"
assert_no_upload "$CASE_DIR"; assert_no_mode
[ ! -e "$(cat "$CASE_DIR/password-file-path")" ] || fail "the password file was left on disk after a failed gate"
pass "personal deck with no gate -> no upload"

echo "[6] API state never reflects the gate (stale): nothing is uploaded"
run_case stale-state 1 STATE_FORCE='{"accessMode":"public","passwordProtected":false}'
assert_no_upload "$CASE_DIR"; assert_no_mode
pass "stale state is not trusted"

echo "[7] existing app whose edge still serves it publicly: nothing is uploaded"
make_fixture "$TMP/edge-stale"
printf '200\n' > "$TMP/edge-stale/gate.values"
run_case edge-stale 1
printf '%s' "$CASE_OUT" | grep >/dev/null 'ERR: access_gate_not_at_edge' || fail "missing edge error: $CASE_OUT"
assert_no_upload "$CASE_DIR"; assert_no_mode
pass "upload waits for the edge to redirect"

echo "[8] gate unproven on the live URL after upload: app is taken down"
make_fixture "$TMP/post-fail"
printf '%s\n' '{"apps":[],"nextCursor":null}' > "$TMP/post-fail/pages/first.json"
printf '200\n' > "$TMP/post-fail/gate.values"
run_case post-fail 1
[ -f "$CASE_DIR/uploaded" ] || fail "fixture should reach upload (new app, no pre-upload edge check)"
[ -f "$CASE_DIR/taken_down" ] || fail "app was not taken down: $(cat "$CASE_DIR/calls")"
assert_before "$CASE_DIR" 'HQ upload summary' 'HQ takedown app-1'
grep -q '^takedown company=acme personal=0 ' "$CASE_DIR/hq-calls" || fail "takedown did not name the company: $(cat "$CASE_DIR/hq-calls")"
printf '%s' "$CASE_OUT" | grep >/dev/null 'ERR: access_gate_unverified_after_upload; app taken down' || fail "missing takedown error: $CASE_OUT"
assert_no_mode
pass "unproven live gate -> takedown, nothing reported as gated"

echo "[9] takedown itself fails: loud error, non-zero exit"
make_fixture "$TMP/takedown-fail"
printf '%s\n' '{"apps":[],"nextCursor":null}' > "$TMP/takedown-fail/pages/first.json"
printf '200\n' > "$TMP/takedown-fail/gate.values"
run_case takedown-fail 1 TAKEDOWN_STATUS=500
printf '%s' "$CASE_OUT" | grep >/dev/null 'TAKEDOWN FAILED' || fail "takedown failure not surfaced: $CASE_OUT"
assert_no_mode
pass "takedown failure is surfaced"

echo "[10] edge propagation after upload retries until 302"
make_fixture "$TMP/propagation"
printf '%s\n' '{"apps":[],"nextCursor":null}' > "$TMP/propagation/pages/first.json"
printf '200\n302\n' > "$TMP/propagation/gate.values"
run_case propagation 0
printf '%s' "$CASE_OUT" | grep >/dev/null '^MODE=company$' || fail "propagated company gate was not accepted: $CASE_OUT"
[ "$(cat "$CASE_DIR/gate.count")" = 2 ] || fail "expected a retry after anonymous edge response 200"
[ ! -f "$CASE_DIR/taken_down" ] || fail "took down a gated app"
pass "post-upload verify waits for edge propagation"

echo "[11] no HQ_DEPLOY_API and no manifest endpoint: the public default https://api.hq.work is used"
run_case default-api 0 HQ_DEPLOY_API=
printf '%s' "$CASE_OUT" | grep >/dev/null '^MODE=company$' || fail "default-API deploy did not finish gated: $CASE_OUT"
bad_hq="$(grep -v ' api=https://api.hq.work ' "$CASE_DIR/hq-calls" || true)"
[ -z "$bad_hq" ] || fail "hq deploy did not use https://api.hq.work: $bad_hq"
grep -q '^list ' "$CASE_DIR/hq-calls" || fail "app list did not go through hq deploy list"
grep -q '^access ' "$CASE_DIR/hq-calls" || fail "gate did not go through hq deploy access"
grep -q '^upload .* api=https://api.hq.work ' "$CASE_DIR/hq-calls" || fail "the upload did not go to https://api.hq.work"
pass "fresh install deploys through https://api.hq.work"

echo "[12] hq deploy upload fails: no MODE, no LIVE, non-zero exit"
run_case upload-fail 1 UPLOAD_FAIL=1
printf '%s' "$CASE_OUT" | grep >/dev/null 'ERR: deploy_upload_failed' || fail "upload failure was not reported: $CASE_OUT"
printf '%s' "$CASE_OUT" | grep >/dev/null '^LIVE=' && fail "a LIVE url was reported after a failed upload: $CASE_OUT"
assert_no_upload "$CASE_DIR"; assert_no_mode
[ ! -f "$CASE_DIR/archive.tar.gz" ] || fail "the archive was left behind after a failed upload"
pass "failed upload is reported and not treated as live"

echo "ALL PASS: deploy-summary-gating"
