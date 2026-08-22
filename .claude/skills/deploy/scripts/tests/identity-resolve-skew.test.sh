#!/usr/bin/env bash
# identity-resolve-skew.test.sh — expiry skew + id_token emission.
#
# Regression for the silent access-gate downgrade of 2026-07-19: the resolver
# accepted any token that was not yet expired, including one with seconds of
# life left. A deploy takes minutes (build, tarball, S3 upload, then the
# access-policy call), so once per token hour the access-policy call 401'd,
# deploy-summary.sh read that as "company unresolvable", and silently shipped
# a password gate in place of the requested members-only gate.
#
# (a) token with an hour left      -> cache hit, and id_token is emitted
# (b) token inside the skew window -> NOT a cache hit (must refresh or re-login)
# (c) token comfortably outside it -> still a cache hit (skew is not too greedy)
# (d) --force-refresh bypasses a future-dated cache token rejected by the API
# (e) a no-op forced refresh cannot return that rejected token as refreshed
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$SCRIPT_DIR/identity-resolve.sh"
FAIL=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "SKIP: host needs jq to assert fixtures"; exit 0; }

NOW_S=$(date +%s)

# Write a token file whose expiresAt is $1 seconds from now.
make_token() {
  local home=$1 offset_s=$2 access=$3
  mkdir -p "$home/.hq"
  printf '{"accessToken":"%s","idToken":"%s.id","refreshToken":"rt","expiresAt":%s}\n' \
    "$access" "$access" "$(( (NOW_S + offset_s) * 1000 ))" > "$home/.hq/cognito-tokens.json"
}

# --- (a) an hour of life -> cache hit, id_token present ----------------------
HOME_OK="$TMP/home-ok"
make_token "$HOME_OK" 3600 "fresh.jwt"
OUT=$(env HOME="$HOME_OK" "$RESOLVER" 2>/dev/null)
if printf '%s\n' "$OUT" | jq -e \
  '.status == "ok" and .source == "cache" and .jwt == "fresh.jwt"' >/dev/null; then
  pass "token with 1h left is a cache hit"
else
  fail "token with 1h left should be a cache hit (got: $OUT)"
fi
if printf '%s\n' "$OUT" | jq -e '.id_token == "fresh.jwt.id"' >/dev/null; then
  pass "id_token is emitted so callers need no raw jq read of the token file"
else
  fail "id_token missing from resolver output (got: $OUT)"
fi

# --- (b) inside the skew window -> must NOT be served from cache -------------
# Isolate PATH to jq+node only: with no hq-auth-refresh/npx/hq on it the
# refresh path no-ops, so a cache hit here would be the original bug. A
# pre-touched login lock keeps the login path from opening a browser.
BIN="$TMP/bin"; mkdir -p "$BIN"
for t in jq node date mktemp; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$BIN/$t"
done
TMPDIR_T="$TMP/tmpdir"; mkdir -p "$TMPDIR_T"
TMPDIR_T="$(cd "$TMPDIR_T" && pwd)"
touch "$TMPDIR_T/hq-deploy-login-attempted-skewtest"

HOME_SOON="$TMP/home-soon"
make_token "$HOME_SOON" 120 "doomed.jwt"   # 2 min left, inside the 5 min skew
OUT=$(env -u USERNAME USER=skewtest HOME="$HOME_SOON" TMPDIR="$TMPDIR_T" \
  PATH="$BIN" /bin/bash "$RESOLVER" 2>/dev/null)
if printf '%s\n' "$OUT" | jq -e '.status == "ok" and .jwt == "doomed.jwt"' >/dev/null; then
  fail "REGRESSION: token expiring in 2 min was served as usable (got: $OUT)"
else
  pass "token expiring inside the skew window is not served from cache"
fi

# --- (c) just outside the window -> still a cache hit ------------------------
HOME_EDGE="$TMP/home-edge"
make_token "$HOME_EDGE" 900 "edge.jwt"     # 15 min left, clear of the 5 min skew
OUT=$(env HOME="$HOME_EDGE" "$RESOLVER" 2>/dev/null)
if printf '%s\n' "$OUT" | jq -e \
  '.status == "ok" and .source == "cache" and .jwt == "edge.jwt"' >/dev/null; then
  pass "token with 15m left is still a cache hit (skew does not over-refresh)"
else
  fail "token with 15m left should be a cache hit (got: $OUT)"
fi

# --- (d) API-rejected token -> force refresh even when expiry is in the future
BIN_REFRESH="$TMP/bin-refresh"; mkdir -p "$BIN_REFRESH"
for t in jq node date mktemp; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$BIN_REFRESH/$t"
done
cat > "$BIN_REFRESH/hq-auth-refresh" <<'STUB'
#!/bin/bash
printf '{"accessToken":"new.jwt","idToken":"new.id","refreshToken":"rt","expiresAt":%s}\n' \
  "$REFRESHED_EXP" > "$HOME/.hq/cognito-tokens.json"
STUB
chmod +x "$BIN_REFRESH/hq-auth-refresh"
HOME_REJECTED="$TMP/home-rejected"
make_token "$HOME_REJECTED" 3600 "rejected.jwt"
REFRESHED_EXP="$(( (NOW_S + 7200) * 1000 ))"
OUT=$(env HOME="$HOME_REJECTED" PATH="$BIN_REFRESH" REFRESHED_EXP="$REFRESHED_EXP" \
  /bin/bash "$RESOLVER" --force-refresh 2>/dev/null)
if printf '%s\n' "$OUT" | jq -e \
  '.status == "ok" and .source == "refresh" and .jwt == "new.jwt" and .id_token == "new.id"' >/dev/null; then
  pass "--force-refresh bypasses a rejected future-dated cache token"
else
  fail "--force-refresh should return the refreshed token (got: $OUT)"
fi

# --- (e) no-op force refresh -> rejected token is never returned as refreshed
BIN_NOOP="$TMP/bin-noop"; mkdir -p "$BIN_NOOP"
for t in jq node date mktemp; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$BIN_NOOP/$t"
done
cat > "$BIN_NOOP/hq-auth-refresh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$BIN_NOOP/hq-auth-refresh"
HOME_NOOP="$TMP/home-noop"
make_token "$HOME_NOOP" 3600 "still-rejected.jwt"
touch "$TMPDIR_T/hq-deploy-login-attempted-nooptest"
OUT=$(env -u USERNAME USER=nooptest HOME="$HOME_NOOP" TMPDIR="$TMPDIR_T" \
  PATH="$BIN_NOOP" /bin/bash "$RESOLVER" --force-refresh 2>/dev/null)
if printf '%s\n' "$OUT" | jq -e \
  '.status == "ok" and .jwt == "still-rejected.jwt"' >/dev/null 2>&1; then
  fail "REGRESSION: no-op forced refresh returned the rejected token (got: $OUT)"
else
  pass "no-op forced refresh never returns the rejected token"
fi

# --- (f) no usable clock -> structured missing_dependency, never a token -----
# The skew comparison is $((NOW_MS + SKEW_MS)), and bash evaluates an empty
# NOW_MS as 0 — which would collapse that bound to 300000 and make ANY real
# expiresAt look current. This resolver already guards the clock (node first,
# then date, else missing_dependency); the case exists to keep that guard
# wired to the skew arithmetic, since the two landed in separate changes and
# nothing else asserts they stay together.
BIN_NOCLOCK="$TMP/bin-noclock"; mkdir -p "$BIN_NOCLOCK"
p=$(command -v jq 2>/dev/null) && ln -sf "$p" "$BIN_NOCLOCK/jq"   # jq only: no node, no date
HOME_EXPIRED="$TMP/home-expired"
make_token "$HOME_EXPIRED" -7200 "long.dead.jwt"   # expired two hours ago
OUT=$(env HOME="$HOME_EXPIRED" PATH="$BIN_NOCLOCK" /bin/bash "$RESOLVER" 2>/dev/null)
if printf '%s\n' "$OUT" | jq -e '.status == "ok"' >/dev/null 2>&1; then
  fail "REGRESSION: with no usable clock the resolver served a token (got: $OUT)"
elif printf '%s\n' "$OUT" | jq -e '.status == "missing_dependency"' >/dev/null 2>&1; then
  pass "no usable clock reports missing_dependency and serves no token"
else
  # Deliberately NOT a pass: empty stdout (a bare crash) leaves the caller with
  # no reason at all. Asserting the structured contract is the point.
  fail "no usable clock should emit missing_dependency, got: '$(printf '%s' "$OUT" | head -c 60)'"
fi

if [ "$FAIL" = "0" ]; then echo "ALL PASS"; exit 0; else echo "FAILURES"; exit 1; fi
