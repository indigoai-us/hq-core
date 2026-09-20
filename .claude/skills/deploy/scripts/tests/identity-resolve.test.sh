#!/usr/bin/env bash
# identity-resolve.test.sh — regression coverage for portable deploy user keys.
# Asserts the resolver works without USER and sanitizes USERNAME for lock paths.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$SCRIPT_DIR/identity-resolve.sh"
FAIL=0
LOGIN_LOCK=""

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
  if [ -n "$LOGIN_LOCK" ]; then rm -f "$LOGIN_LOCK"; fi
}
trap cleanup EXIT

FUTURE_MS=$((($(date +%s) + 3600) * 1000))
make_token() {
  local home=$1 jwt=$2
  mkdir -p "$home/.hq"
  jq -n --arg jwt "$jwt" --argjson expires "$FUTURE_MS" \
    '{accessToken:$jwt, expiresAt:$expires}' > "$home/.hq/cognito-tokens.json"
}

make_machine_creds() {
  local home=$1
  mkdir -p "$home/.hq-agent"
  # Detection is file-based, like the CLI. Keep fake values so no credential is
  # ever used by this test; hq-auth-refresh is stubbed on PATH below.
  printf '{"username":"machine-test","secret":"fake"}\n' > "$home/.hq-agent/machine-creds.json"
}

HOME_USERNAME="$TMP/home-username"
make_token "$HOME_USERNAME" "username.jwt"
OUTPUT=$(env -u USER -u HQ_MACHINE_CREDS_FILE -u HQ_MACHINE_TOKEN_STATE_DIR -u HQ_WORK_MESH_ROOT \
  USERNAME=windows-user HOME="$HOME_USERNAME" "$RESOLVER" 2>"$TMP/username.err")
STATUS=$?
if [ "$STATUS" = "0" ] && printf '%s\n' "$OUTPUT" | jq -e \
  --argjson expires "$FUTURE_MS" \
  '.status == "ok" and .jwt == "username.jwt" and .expires_at == $expires and .source == "cache"' >/dev/null; then
  pass "USER unset falls back to USERNAME"
else
  fail "USER unset should return valid cache status JSON"
fi

# Machine identities must mint non-interactively, return the ID token for both
# callers, and never create the human browser-login lock.
BIN_MACHINE="$TMP/bin-machine"
mkdir -p "$BIN_MACHINE"
cat > "$BIN_MACHINE/hq-auth-refresh" <<'STUB'
#!/bin/bash
printf '%s\n' called >> "$MACHINE_REFRESH_LOG"
mkdir -p "$HQ_MACHINE_TOKEN_STATE_DIR"
printf '{"accessToken":"machine.access","idToken":"machine.id","expiresAt":%s}\n' "$MACHINE_EXPIRES" > "$HQ_MACHINE_TOKEN_STATE_DIR/cognito-tokens.json"
STUB
chmod +x "$BIN_MACHINE/hq-auth-refresh"
HOME_MACHINE="$TMP/home-machine"
make_machine_creds "$HOME_MACHINE"
MACHINE_REFRESH_LOG="$TMP/machine-refresh.log"
MACHINE_TOKEN_STATE_DIR="$TMP/machine-token-state"
MACHINE_EXPIRES=$((($(date +%s) + 3600) * 1000))
# Only the hq-auth-refresh stub is placed on PATH; the real jq/node/date/mkdir
# resolve from the inherited PATH, because symlinking real tools into a fake bin
# dir breaks under Git-bash on Windows.
OUTPUT=$(HOME="$HOME_MACHINE" USER=machine-user TMPDIR="$TMP/machine-tmp" \
  HQ_MACHINE_CREDS_FILE="$HOME_MACHINE/.hq-agent/machine-creds.json" \
  HQ_MACHINE_TOKEN_STATE_DIR="$MACHINE_TOKEN_STATE_DIR" \
  PATH="$BIN_MACHINE:$PATH" MACHINE_REFRESH_LOG="$MACHINE_REFRESH_LOG" MACHINE_EXPIRES="$MACHINE_EXPIRES" \
  /bin/bash "$RESOLVER" 2>"$TMP/machine.err")
STATUS=$?
MACHINE_LOCK="$TMP/machine-tmp/hq-deploy-login-attempted-machine-user"
if [ "$STATUS" = "0" ] && printf '%s\n' "$OUTPUT" | jq -e \
  '.status == "ok" and .identity == "machine" and .jwt == "machine.id" and .id_token == "machine.id" and .source == "machine_mint"' >/dev/null \
  && [ "$(wc -l < "$MACHINE_REFRESH_LOG" | tr -d ' ')" = "1" ] \
  && [ ! -e "$MACHINE_LOCK" ]; then
  pass "machine credentials mint non-interactively and return the ID token"
else
  fail "machine resolver should mint without browser login (got: $OUTPUT)"
fi

# A failed machine mint must stop immediately, without the login lock/browser
# fallback used by the human path.
BIN_MACHINE_FAIL="$TMP/bin-machine-fail"
mkdir -p "$BIN_MACHINE_FAIL"
printf '#!/bin/bash\nexit 1\n' > "$BIN_MACHINE_FAIL/hq-auth-refresh"
chmod +x "$BIN_MACHINE_FAIL/hq-auth-refresh"
HOME_MACHINE_FAIL="$TMP/home-machine-fail"
make_machine_creds "$HOME_MACHINE_FAIL"
OUTPUT=$(HOME="$HOME_MACHINE_FAIL" USER=machine-fail TMPDIR="$TMP/machine-fail-tmp" \
  HQ_MACHINE_CREDS_FILE="$HOME_MACHINE_FAIL/.hq-agent/machine-creds.json" \
  PATH="$BIN_MACHINE_FAIL:$PATH" /bin/bash "$RESOLVER" 2>"$TMP/machine-fail.err")
STATUS=$?
MACHINE_FAIL_LOCK="$TMP/machine-fail-tmp/hq-deploy-login-attempted-machine-fail"
if [ "$STATUS" = "0" ] && printf '%s\n' "$OUTPUT" | jq -e \
  '.status == "login_required" and .reason == "machine_mint_failed"' >/dev/null \
  && [ ! -e "$MACHINE_FAIL_LOCK" ] \
  && ! grep -q 'Opening HQ sign-in' "$TMP/machine-fail.err"; then
  pass "failed machine mint does not attempt browser login or create a lock"
else
  fail "failed machine mint should fail closed without browser login (got: $OUTPUT)"
fi

# An explicitly configured but missing machine credentials file is a
# machine-mode signal. It must not fall through to the human browser flow.
HOME_MACHINE_MISSING="$TMP/home-machine-missing"
OUTPUT=$(HOME="$HOME_MACHINE_MISSING" USER=machine-missing TMPDIR="$TMP/machine-missing-tmp" \
  HQ_MACHINE_CREDS_FILE="$HOME_MACHINE_MISSING/missing-machine-creds.json" \
  HQ_MACHINE_TOKEN_STATE_DIR="$TMP/machine-missing-token-state" \
  /bin/bash "$RESOLVER" 2>"$TMP/machine-missing.err")
STATUS=$?
MACHINE_MISSING_LOCK="$TMP/machine-missing-tmp/hq-deploy-login-attempted-machine-missing"
if [ "$STATUS" = "0" ] && printf '%s\n' "$OUTPUT" | jq -e \
  '.status == "login_required" and .reason == "machine_mint_failed"' >/dev/null \
  && [ ! -e "$MACHINE_MISSING_LOCK" ] \
  && ! grep -q 'Opening HQ sign-in' "$TMP/machine-missing.err"; then
  pass "missing configured machine credentials fail closed without browser login"
else
  fail "missing configured machine credentials should not reach browser login (got: $OUTPUT)"
fi

HOME_UNKNOWN="$TMP/home-unknown"
make_token "$HOME_UNKNOWN" "unknown.jwt"
OUTPUT=$(env -u USER -u USERNAME -u HQ_MACHINE_CREDS_FILE -u HQ_MACHINE_TOKEN_STATE_DIR -u HQ_WORK_MESH_ROOT \
  HOME="$HOME_UNKNOWN" "$RESOLVER" 2>"$TMP/unknown.err")
STATUS=$?
if [ "$STATUS" = "0" ] && printf '%s\n' "$OUTPUT" | jq -e \
  --argjson expires "$FUTURE_MS" \
  '.status == "ok" and .jwt == "unknown.jwt" and .expires_at == $expires and .source == "cache"' >/dev/null; then
  pass "missing USER and USERNAME use the unknown fallback"
else
  fail "missing USER and USERNAME should return valid cache status JSON"
fi

SAFE_USERNAME="win/${TMP##*/} user"
SAFE_KEY="win_${TMP##*/}_user"
# Use a private TMPDIR so the lock path is isolated and asserts ${TMPDIR:-/tmp}.
TMPDIR_TEST="$TMP/tmpdir"
mkdir -p "$TMPDIR_TEST" "$TMP/home-lock"
TMPDIR_TEST="$(cd "$TMPDIR_TEST" && pwd)"
LOGIN_LOCK="$TMPDIR_TEST/hq-deploy-login-attempted-$SAFE_KEY"
touch "$LOGIN_LOCK"
# Keep real PATH (jq/node required for engine probe); lock short-circuits before login.
OUTPUT=$(env -u USER -u HQ_MACHINE_CREDS_FILE -u HQ_MACHINE_TOKEN_STATE_DIR -u HQ_WORK_MESH_ROOT \
  USERNAME="$SAFE_USERNAME" HOME="$TMP/home-lock" \
  TMPDIR="$TMPDIR_TEST" \
  /bin/bash "$RESOLVER" 2>"$TMP/lock.err")
STATUS=$?
if [ "$STATUS" = "0" ] && [ "$(printf '%s\n' "$OUTPUT" | jq -r '.reason // empty')" = "login_already_attempted" ]; then
  pass "USERNAME is sanitized for the login lock path under TMPDIR"
else
  fail "resolver did not use the sanitized login lock path under TMPDIR (got: $OUTPUT)"
fi

if [ "$FAIL" = "0" ]; then echo "ALL PASS"; exit 0; else echo "FAILURES"; exit 1; fi
