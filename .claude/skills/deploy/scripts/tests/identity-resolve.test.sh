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

HOME_USERNAME="$TMP/home-username"
make_token "$HOME_USERNAME" "username.jwt"
OUTPUT=$(env -u USER USERNAME=windows-user HOME="$HOME_USERNAME" "$RESOLVER" 2>"$TMP/username.err")
STATUS=$?
if [ "$STATUS" = "0" ] && printf '%s\n' "$OUTPUT" | jq -e \
  --argjson expires "$FUTURE_MS" \
  '.status == "ok" and .jwt == "username.jwt" and .expires_at == $expires and .source == "cache"' >/dev/null; then
  pass "USER unset falls back to USERNAME"
else
  fail "USER unset should return valid cache status JSON"
fi

HOME_UNKNOWN="$TMP/home-unknown"
make_token "$HOME_UNKNOWN" "unknown.jwt"
OUTPUT=$(env -u USER -u USERNAME HOME="$HOME_UNKNOWN" "$RESOLVER" 2>"$TMP/unknown.err")
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
OUTPUT=$(env -u USER USERNAME="$SAFE_USERNAME" HOME="$TMP/home-lock" \
  TMPDIR="$TMPDIR_TEST" \
  /bin/bash "$RESOLVER" 2>"$TMP/lock.err")
STATUS=$?
if [ "$STATUS" = "0" ] && [ "$(printf '%s\n' "$OUTPUT" | jq -r '.reason // empty')" = "login_already_attempted" ]; then
  pass "USERNAME is sanitized for the login lock path under TMPDIR"
else
  fail "resolver did not use the sanitized login lock path under TMPDIR (got: $OUTPUT)"
fi

if [ "$FAIL" = "0" ]; then echo "ALL PASS"; exit 0; else echo "FAILURES"; exit 1; fi
