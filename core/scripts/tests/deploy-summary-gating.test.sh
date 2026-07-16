#!/usr/bin/env bash
# Regression: project-summary deploys must prove an access gate before reporting
# it. A failed mutation, stale app state, or an unpropagated edge redirect must
# never result in MODE=company/password output for an effectively public app.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SRC="$ROOT/.claude/skills/project-summary/scripts/deploy-summary.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$SRC" ] || fail "deploy-summary.sh not found at $SRC"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

make_fixture() {
  local case_dir="$1"
  mkdir -p "$case_dir/.claude/skills/project-summary/scripts" \
    "$case_dir/.claude/skills/deploy/scripts" "$case_dir/bin" \
    "$case_dir/build" "$case_dir/companies"
  cp "$SRC" "$case_dir/.claude/skills/project-summary/scripts/deploy-summary.sh"
  printf '<!doctype html>\n' > "$case_dir/build/index.html"
  printf 'companies:\n  acme:\n    cloud_uid: cmp_acme\n' > "$case_dir/companies/manifest.yaml"
  cat > "$case_dir/.claude/skills/deploy/scripts/identity-resolve.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"jwt":"test-jwt"}'
EOF
  cat > "$case_dir/.claude/skills/deploy/scripts/guardrails-check.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"pass":true,"tarball_path":"/tmp/deploy-summary-gating.tar.gz","size_bytes":1,"sha256":"test-sha"}'
EOF
  cat > "$case_dir/.claude/skills/deploy/scripts/password-helper.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  gen) printf '%s\n' 'test-password' ;;
  announce) exit 0 ;;
esac
EOF
  chmod +x "$case_dir/.claude/skills/deploy/scripts/"*.sh
  cat > "$case_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
method=GET
for ((i=1; i <= $#; i++)); do
  case "${!i}" in http://*|https://*) url="${!i}" ;; esac
  if [ "${!i}" = "-X" ]; then
    next=$((i + 1)); method="${!next}"
  fi
done
next_value() {
  local name="$1" count_file="$MOCK_DIR/$1.count" values="$MOCK_DIR/$1.values" n value
  n=0; [ -f "$count_file" ] && n="$(cat "$count_file")"
  n=$((n + 1)); printf '%s' "$n" > "$count_file"
  value="$(sed -n "${n}p" "$values" 2>/dev/null || true)"
  [ -n "$value" ] || value="$(tail -n 1 "$values")"
  printf '%s' "$value"
}
case "$url" in
  http://api.test/api/apps)
    if [ "$method" = POST ]; then
      printf '%s\n' '{"subdomain":"summary"}'
    elif [ -n "${APPS_JSON:-}" ]; then
      printf '%s\n' "$APPS_JSON"
    else
      printf '%s\n' '{"apps":[{"name":"summary","subdomain":"summary","id":"app-1"}]}'
    fi ;;
  http://api.test/api/deploys)
    printf '%s\n' '{"deployId":"deploy-1","presignedUrl":"http://upload.test/archive"}' ;;
  http://upload.test/archive)
    : ;;
  http://api.test/api/deploys/deploy-1/complete)
    printf '%s\n' '{"url":"http://live.test"}' ;;
  http://api.test/api/apps/app-1/access-policy)
    printf '%s' "$PUT_STATUS" ;;
  http://api.test/api/apps/app-1/access-mode)
    printf '%s' "$PASSWORD_STATUS" ;;
  http://api.test/api/apps/app-1)
    case "$*" in *'Authorization: Bearer test-jwt'*) ;; *) echo 'state reread was unauthenticated' >&2; exit 8 ;; esac
    printf '%s\n200' "$(next_value state)" ;;
  http://live.test/)
    case "$*" in *Authorization*) echo 'edge verification was not anonymous' >&2; exit 8 ;; esac
    next_value gate ;;
  *)
    echo "unexpected curl request: $method $url" >&2
    exit 9 ;;
esac
EOF
  chmod +x "$case_dir/bin/curl"
}

run_case() {
  local name="$1" put_status="$2" password_status="$3" states="$4" gates="$5" expected_code="$6"
  local case_dir="$TMP/$name" out code
  make_fixture "$case_dir"
  printf '%s\n' "$states" > "$case_dir/state.values"
  printf '%s\n' "$gates" > "$case_dir/gate.values"
  set +e
  out="$(PATH="$case_dir/bin:$PATH" MOCK_DIR="$case_dir" PUT_STATUS="$put_status" PASSWORD_STATUS="$password_status" \
    HQ_DEPLOY_API='http://api.test' bash "$case_dir/.claude/skills/project-summary/scripts/deploy-summary.sh" \
    "$case_dir/build" summary acme 2>&1)"
  code=$?
  set -e
  [ "$code" -eq "$expected_code" ] || fail "$name exit=$code, expected $expected_code: $out"
  CASE_OUT="$out"
  CASE_DIR="$case_dir"
}

run_unresolved_app_id_case() {
  local case_dir="$TMP/unresolved-app-id" out code
  make_fixture "$case_dir"
  set +e
  out="$(PATH="$case_dir/bin:$PATH" MOCK_DIR="$case_dir" PUT_STATUS=204 PASSWORD_STATUS=200 \
    APPS_JSON='{"apps":[]}' HQ_DEPLOY_API='http://api.test' \
    bash "$case_dir/.claude/skills/project-summary/scripts/deploy-summary.sh" \
    "$case_dir/build" summary acme 2>&1)"
  code=$?
  set -e
  [ "$code" -ne 0 ] || fail "unresolved app id unexpectedly succeeded: $out"
  printf '%s' "$out" | grep -q 'ERR: app_id_unresolved' \
    || fail "unresolved app id did not fail explicitly: $out"
}

echo "[1] PUT 400 does not emit company mode; proven password fallback is used"
run_case put-400 400 200 \
  '{"accessMode":"password","passwordProtected":true}' \
  302 0
printf '%s' "$CASE_OUT" | grep -q '^MODE=password$' || fail "PUT 400 did not use password fallback: $CASE_OUT"
printf '%s' "$CASE_OUT" | grep -q '^MODE=company$' && fail "PUT 400 emitted an unproven company mode: $CASE_OUT"
pass "non-2xx company mutation fails closed"

echo "[2] stale authenticated company state retries, then falls back to a proven password gate"
run_case stale-state 204 200 \
  '{"accessMode":"public","passwordProtected":false}
{"accessMode":"public","passwordProtected":false}
{"accessMode":"public","passwordProtected":false}
{"accessMode":"password","passwordProtected":true}' \
  302 0
printf '%s' "$CASE_OUT" | grep -q '^MODE=password$' || fail "stale state was accepted as company gate: $CASE_OUT"
[ "$(cat "$CASE_DIR/state.count")" = 4 ] || fail "expected three company rereads plus password reread"
pass "stale state is not trusted"

echo "[3] edge propagation retries until the anonymous redirect is 302"
run_case propagation 204 200 \
  '{"accessPolicy":{"mode":"company","companyUid":"cmp_acme"}}
{"accessPolicy":{"mode":"company","companyUid":"cmp_acme"}}' \
  '200
302' 0
printf '%s' "$CASE_OUT" | grep -q '^MODE=company$' || fail "propagated company gate was not accepted: $CASE_OUT"
[ "$(cat "$CASE_DIR/gate.count")" = 2 ] || fail "expected a retry after anonymous edge response 200"
pass "company gate waits for anonymous redirect propagation"

echo "[4] unresolved app IDs are rejected before access mutation"
run_unresolved_app_id_case
pass "unresolved app ID fails explicitly"

echo "[5] when neither company nor password gate is proven, the deploy exits non-zero"
run_case fallback-failure 400 400 \
  '{"accessMode":"public","passwordProtected":false}' \
  200 1
printf '%s' "$CASE_OUT" | grep -q 'ERR: access_gate_unverified' || fail "missing fail-closed error: $CASE_OUT"
printf '%s' "$CASE_OUT" | grep -q '^MODE=' && fail "unproven fallback emitted a mode: $CASE_OUT"
pass "no unproven deploy is reported as gated"

echo "ALL PASS: deploy-summary-gating"
