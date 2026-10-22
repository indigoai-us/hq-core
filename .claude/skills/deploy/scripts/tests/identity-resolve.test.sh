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
mkdir -p "$TMP/machine-tmp"
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
mkdir -p "$TMP/machine-fail-tmp"
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

# feedback_1eaa57d7: the daemon's cached machine token can make the normal
# refresh fail (stale or rejected cache). The resolver must retry once with the
# one-day floor, which skips that cache and mints fresh, instead of failing.
BIN_MACHINE_STALE="$TMP/bin-machine-stale"
mkdir -p "$BIN_MACHINE_STALE"
cat > "$BIN_MACHINE_STALE/hq-auth-refresh" <<'STUB'
#!/bin/bash
printf '%s\n' "${HQ_AUTH_MIN_VALIDITY_SECONDS:-120}" >> "$MACHINE_STALE_LOG"
[ "${HQ_AUTH_MIN_VALIDITY_SECONDS:-120}" -ge 86400 ] || exit 1
mkdir -p "$HQ_MACHINE_TOKEN_STATE_DIR"
printf '{"accessToken":"remint-access","idToken":"remint-id","expiresAt":%s}\n' \
  "$(( ($(date +%s) + 3600) * 1000 ))" > "$HQ_MACHINE_TOKEN_STATE_DIR/cognito-tokens.json"
STUB
chmod +x "$BIN_MACHINE_STALE/hq-auth-refresh"
HOME_MACHINE_STALE="$TMP/home-machine-stale"
make_machine_creds "$HOME_MACHINE_STALE"
MACHINE_STALE_STATE="$TMP/machine-stale-state"
mkdir -p "$MACHINE_STALE_STATE" "$TMP/machine-stale-tmp"
printf '{"accessToken":"old-access","idToken":"old-id","expiresAt":1}\n' > "$MACHINE_STALE_STATE/cognito-tokens.json"
MACHINE_STALE_LOG="$TMP/machine-stale.log"
OUTPUT=$(env -u HQ_AUTH_MIN_VALIDITY_SECONDS \
  HOME="$HOME_MACHINE_STALE" USER=machine-stale TMPDIR="$TMP/machine-stale-tmp" \
  HQ_MACHINE_CREDS_FILE="$HOME_MACHINE_STALE/.hq-agent/machine-creds.json" \
  HQ_MACHINE_TOKEN_STATE_DIR="$MACHINE_STALE_STATE" \
  MACHINE_STALE_LOG="$MACHINE_STALE_LOG" \
  PATH="$BIN_MACHINE_STALE:$PATH" /bin/bash "$RESOLVER" 2>"$TMP/machine-stale.err")
STATUS=$?
if [ "$STATUS" = "0" ] && printf '%s\n' "$OUTPUT" | jq -e \
  '.status == "ok" and .identity == "machine" and .jwt == "remint-id" and .source == "machine_mint"' >/dev/null \
  && [ "$(tr '\n' ' ' < "$MACHINE_STALE_LOG")" = "300 86400 " ]; then
  pass "stale cached machine token is re-minted once instead of machine_mint_failed"
else
  fail "stale cached machine token should be re-minted once (got: $OUTPUT; calls: $(cat "$MACHINE_STALE_LOG" 2>/dev/null))"
fi

# A realistic refresh stub follows the hq-auth-refresh cache threshold: it
# keeps a cached token with more than HQ_AUTH_MIN_VALIDITY_SECONDS remaining
# (default 120), otherwise it writes a fresh test placeholder. No real CLI or
# credential is used by these cases.
make_threshold_refresh_bin() {
  local bin=$1
  mkdir -p "$bin"
  cat > "$bin/hq-auth-refresh" <<'STUB'
#!/bin/bash
minimum=${HQ_AUTH_MIN_VALIDITY_SECONDS:-120}
printf '%s\n' "$minimum" >> "$MACHINE_MIN_VALIDITY_LOG"
cache="$HQ_MACHINE_TOKEN_STATE_DIR/cognito-tokens.json"
expires=$(jq -r '.expiresAt // 0' "$cache")
now_ms=$(( $(date +%s) * 1000 ))
remaining=$(( (expires - now_ms) / 1000 ))
if [ "$remaining" -gt "$minimum" ]; then
  exit 0
fi
fresh_expires=$(( ($(date +%s) + 3600) * 1000 ))
printf '{"accessToken":"fresh-access-placeholder","idToken":"fresh-id-placeholder","expiresAt":%s}\n' "$fresh_expires" > "$cache"
STUB
  chmod +x "$bin/hq-auth-refresh"
}

make_machine_cache() {
  local state_dir=$1 expires=$2
  mkdir -p "$state_dir"
  # These are non-credential placeholders used only in the temporary fixture.
  printf '{"accessToken":"cached-placeholder","idToken":"cached-id-placeholder","expiresAt":%s}\n' \
    "$expires" > "$state_dir/cognito-tokens.json"
}

# A machine cache with 200 seconds left is above the CLI's default 120s
# threshold but below this resolver's five-minute skew. The override must make
# the stub mint and the resolver must return its fresh placeholder.
BIN_MACHINE_MARGIN="$TMP/bin-machine-margin"
make_threshold_refresh_bin "$BIN_MACHINE_MARGIN"
HOME_MACHINE_MARGIN="$TMP/home-machine-margin"
make_machine_creds "$HOME_MACHINE_MARGIN"
MACHINE_MARGIN_STATE="$TMP/machine-margin-state"
NOW_S=$(date +%s)
make_machine_cache "$MACHINE_MARGIN_STATE" "$(((NOW_S + 200) * 1000))"
MACHINE_MARGIN_LOG="$TMP/machine-margin-validity.log"
TMPDIR_MARGIN="$TMP/machine-margin-tmp"
mkdir -p "$TMPDIR_MARGIN"
OUTPUT=$(env -u HQ_AUTH_MIN_VALIDITY_SECONDS \
  HOME="$HOME_MACHINE_MARGIN" USER=machine-margin TMPDIR="$TMPDIR_MARGIN" \
  HQ_MACHINE_CREDS_FILE="$HOME_MACHINE_MARGIN/.hq-agent/machine-creds.json" \
  HQ_MACHINE_TOKEN_STATE_DIR="$MACHINE_MARGIN_STATE" \
  MACHINE_MIN_VALIDITY_LOG="$MACHINE_MARGIN_LOG" \
  PATH="$BIN_MACHINE_MARGIN:$PATH" /bin/bash "$RESOLVER" 2>"$TMP/machine-margin.err")
STATUS=$?
MACHINE_MARGIN=$(cat "$MACHINE_MARGIN_LOG" 2>/dev/null || true)
if [ "$STATUS" = "0" ] \
  && printf '%s\n' "$OUTPUT" | jq -e \
    '.status == "ok" and .identity == "machine" and .jwt == "fresh-id-placeholder" and .source == "machine_mint"' >/dev/null \
  && [ "$MACHINE_MARGIN" = "300" ]; then
  pass "machine token with 200s left is refreshed using the 300s minimum"
else
  fail "machine token with 200s left should be freshly minted using 300s minimum"
fi

# Exercise the npx fallback as well as the direct executable branch. Forced
# refresh deliberately sets a day so any normal Cognito token is considered
# expiring; the stub must see that exact value and mint the cached 3000s token.
BIN_MACHINE_NPX="$TMP/bin-machine-npx"
BIN_MACHINE_NPX_REFRESH="$TMP/bin-machine-npx-refresh"
mkdir -p "$BIN_MACHINE_NPX"
make_threshold_refresh_bin "$BIN_MACHINE_NPX_REFRESH"
cat > "$BIN_MACHINE_NPX/npx" <<'STUB'
#!/bin/bash
printf '%s\n' "${HQ_AUTH_MIN_VALIDITY_SECONDS:-unset}" >> "$NPX_MIN_VALIDITY_LOG"
exec "$HQ_TEST_REFRESH_BIN"
STUB
chmod +x "$BIN_MACHINE_NPX/npx"
HOME_MACHINE_FORCE="$TMP/home-machine-force"
make_machine_creds "$HOME_MACHINE_FORCE"
MACHINE_FORCE_STATE="$TMP/machine-force-state"
NOW_S=$(date +%s)
make_machine_cache "$MACHINE_FORCE_STATE" "$(((NOW_S + 3000) * 1000))"
NPX_VALIDITY_LOG="$TMP/npx-min-validity.log"
MACHINE_NPX_VALIDITY_LOG="$TMP/machine-npx-underlying-validity.log"
TMPDIR_FORCE="$TMP/machine-force-tmp"
mkdir -p "$TMPDIR_FORCE"
PATH_WITHOUT_HQ_AUTH_REFRESH=""
OLD_IFS=$IFS
IFS=:
for path_entry in $PATH; do
  [ -x "$path_entry/hq-auth-refresh" ] && continue
  if [ -n "$PATH_WITHOUT_HQ_AUTH_REFRESH" ]; then
    PATH_WITHOUT_HQ_AUTH_REFRESH="$PATH_WITHOUT_HQ_AUTH_REFRESH:$path_entry"
  else
    PATH_WITHOUT_HQ_AUTH_REFRESH="$path_entry"
  fi
done
IFS=$OLD_IFS
OUTPUT=$(env -u HQ_AUTH_MIN_VALIDITY_SECONDS \
  HOME="$HOME_MACHINE_FORCE" USER=machine-force TMPDIR="$TMPDIR_FORCE" \
  HQ_MACHINE_CREDS_FILE="$HOME_MACHINE_FORCE/.hq-agent/machine-creds.json" \
  HQ_MACHINE_TOKEN_STATE_DIR="$MACHINE_FORCE_STATE" \
  NPX_MIN_VALIDITY_LOG="$NPX_VALIDITY_LOG" \
  MACHINE_MIN_VALIDITY_LOG="$MACHINE_NPX_VALIDITY_LOG" \
  HQ_TEST_REFRESH_BIN="$BIN_MACHINE_NPX_REFRESH/hq-auth-refresh" \
  PATH="$BIN_MACHINE_NPX:$PATH_WITHOUT_HQ_AUTH_REFRESH" \
  /bin/bash "$RESOLVER" --force-refresh 2>"$TMP/machine-force.err")
STATUS=$?
NPX_MIN_VALIDITY=$(cat "$NPX_VALIDITY_LOG" 2>/dev/null || true)
MACHINE_NPX_MIN_VALIDITY=$(cat "$MACHINE_NPX_VALIDITY_LOG" 2>/dev/null || true)
if [ "$STATUS" = "0" ] \
  && printf '%s\n' "$OUTPUT" | jq -e \
    '.status == "ok" and .identity == "machine" and .jwt == "fresh-id-placeholder" and .source == "machine_mint"' >/dev/null \
  && [ "$NPX_MIN_VALIDITY" = "86400" ] \
  && [ "$MACHINE_NPX_MIN_VALIDITY" = "86400" ]; then
  pass "machine --force-refresh sends 86400s minimum through npx and mints"
else
  fail "machine --force-refresh should force a mint through npx"
fi

# Refresh failures preserve the machine_mint_failed reason and expose only the
# last stderr line as bounded JSON detail. The private temp file must be removed.
BIN_MACHINE_DETAIL="$TMP/bin-machine-detail"
mkdir -p "$BIN_MACHINE_DETAIL"
cat > "$BIN_MACHINE_DETAIL/hq-auth-refresh" <<'STUB'
#!/bin/bash
printf '%s\n' 'an earlier diagnostic line' >&2
printf '%s%0250d\n' 'refresh "failed" at C:\fake\path ' 0 >&2
exit 1
STUB
chmod +x "$BIN_MACHINE_DETAIL/hq-auth-refresh"
HOME_MACHINE_DETAIL="$TMP/home-machine-detail"
make_machine_creds "$HOME_MACHINE_DETAIL"
TMPDIR_DETAIL="$TMP/machine-detail-tmp"
mkdir -p "$TMPDIR_DETAIL"
OUTPUT=$(env -u HQ_AUTH_MIN_VALIDITY_SECONDS \
  HOME="$HOME_MACHINE_DETAIL" USER=machine-detail TMPDIR="$TMPDIR_DETAIL" \
  HQ_MACHINE_CREDS_FILE="$HOME_MACHINE_DETAIL/.hq-agent/machine-creds.json" \
  PATH="$BIN_MACHINE_DETAIL:$PATH" /bin/bash "$RESOLVER" 2>"$TMP/machine-detail.err")
STATUS=$?
EXPECTED_MINT_DETAIL='refresh "failed" at C:\fake\path'
if [ "$STATUS" = "0" ] && printf '%s\n' "$OUTPUT" | jq -e --arg expected "$EXPECTED_MINT_DETAIL" \
  '.status == "login_required" and .reason == "machine_mint_failed" and (.detail | startswith($expected) and length == 200)' >/dev/null \
  && ! compgen -G "$TMPDIR_DETAIL/hq-auth-refresh.*" >/dev/null; then
  pass "failed machine mint returns escaped last stderr line and removes temp file"
else
  fail "failed machine mint should return valid JSON with escaped detail and clean up"
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

# Shepherd 2367: an agent kit left a machine cache in the shared default
# location on a person's laptop. With no machine credentials and a valid person
# session, the resolver must use the person session and never call the mint.
BIN_STRAY="$TMP/bin-stray"
mkdir -p "$BIN_STRAY"
printf '#!/bin/bash\nprintf called >> "$STRAY_REFRESH_LOG"\nexit 1\n' > "$BIN_STRAY/hq-auth-refresh"
chmod +x "$BIN_STRAY/hq-auth-refresh"
HOME_STRAY="$TMP/home-stray"
make_token "$HOME_STRAY" "person.jwt"
make_machine_cache "$HOME_STRAY/.hq/work-mesh/daemon" "$FUTURE_MS"
STRAY_REFRESH_LOG="$TMP/stray-refresh.log"
OUTPUT=$(env -u HQ_MACHINE_CREDS_FILE -u HQ_MACHINE_TOKEN_STATE_DIR -u HQ_WORK_MESH_ROOT \
  HOME="$HOME_STRAY" USER=stray-user TMPDIR="$TMP/stray-tmp" \
  STRAY_REFRESH_LOG="$STRAY_REFRESH_LOG" PATH="$BIN_STRAY:$PATH" \
  /bin/bash "$RESOLVER" 2>"$TMP/stray.err")
STATUS=$?
if [ "$STATUS" = "0" ] && printf '%s\n' "$OUTPUT" | jq -e \
  '.status == "ok" and .identity == "person" and .jwt == "person.jwt" and .source == "cache"' >/dev/null \
  && [ ! -e "$STRAY_REFRESH_LOG" ]; then
  pass "stray machine cache without machine creds keeps the person session"
else
  fail "stray machine cache without machine creds should resolve the person session (got: $OUTPUT)"
fi

# Without a person session the same stray cache still fails closed in machine
# mode, so a damaged agent never reaches the human browser sign-in.
HOME_STRAY_ONLY="$TMP/home-stray-only"
make_machine_cache "$HOME_STRAY_ONLY/.hq/work-mesh/daemon" "$FUTURE_MS"
OUTPUT=$(env -u HQ_MACHINE_CREDS_FILE -u HQ_MACHINE_TOKEN_STATE_DIR -u HQ_WORK_MESH_ROOT \
  HOME="$HOME_STRAY_ONLY" USER=stray-only TMPDIR="$TMP/stray-tmp" \
  /bin/bash "$RESOLVER" 2>"$TMP/stray-only.err")
if printf '%s\n' "$OUTPUT" | jq -e '.status == "login_required" and .reason == "machine_mint_failed"' >/dev/null \
  && ! grep -q 'Opening HQ sign-in' "$TMP/stray-only.err"; then
  pass "machine cache alone with no person session still fails closed"
else
  fail "machine cache alone with no person session should fail closed (got: $OUTPUT)"
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

# Regression (feedback_7dc25705): a login lock older than the TTL is stale and
# must not block login forever. A stub hq makes the login attempt a no-op.
mkdir -p "$TMP/stub-bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/stub-bin/hq"
chmod +x "$TMP/stub-bin/hq"
touch -t 200001010000 "$LOGIN_LOCK"
OUTPUT=$(env -u USER -u HQ_MACHINE_CREDS_FILE -u HQ_MACHINE_TOKEN_STATE_DIR -u HQ_WORK_MESH_ROOT \
  USERNAME="$SAFE_USERNAME" HOME="$TMP/home-lock" TMPDIR="$TMPDIR_TEST" \
  PATH="$TMP/stub-bin:$PATH" /bin/bash "$RESOLVER" 2>"$TMP/stale.err")
STATUS=$?
if [ "$STATUS" = "0" ] && [ "$(printf '%s\n' "$OUTPUT" | jq -r '.reason // empty')" = "login_attempt_failed" ] \
  && [ -z "$(find "$LOGIN_LOCK" -prune -mmin +1 2>/dev/null)" ]; then
  pass "a stale login lock past its TTL is retaken and login is retried"
else
  fail "stale login lock still blocked login (got: $OUTPUT)"
fi
# The freshly retaken lock blocks again within the TTL.
OUTPUT=$(env -u USER -u HQ_MACHINE_CREDS_FILE -u HQ_MACHINE_TOKEN_STATE_DIR -u HQ_WORK_MESH_ROOT \
  USERNAME="$SAFE_USERNAME" HOME="$TMP/home-lock" TMPDIR="$TMPDIR_TEST" \
  PATH="$TMP/stub-bin:$PATH" /bin/bash "$RESOLVER" 2>/dev/null)
if [ "$(printf '%s\n' "$OUTPUT" | jq -r '.reason // empty')" = "login_already_attempted" ]; then
  pass "a fresh login lock still blocks a second login inside the TTL"
else
  fail "fresh login lock did not block (got: $OUTPUT)"
fi

if [ "$FAIL" = "0" ]; then echo "ALL PASS"; exit 0; else echo "FAILURES"; exit 1; fi
