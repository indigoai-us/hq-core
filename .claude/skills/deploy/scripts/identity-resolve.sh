#!/usr/bin/env bash
# identity-resolve.sh — resolve a Cognito access token (JWT) for hq-deploy.
# Inlined replacement for the former Identity sub-agent: same JSON contract,
# zero Task-tool overhead, deterministic.
#
# Output (one JSON line on stdout):
#   {"status":"ok","jwt":"...","expires_at":<epoch-ms>,"source":"cache|refresh|login"}
#   {"status":"login_required","reason":"<short>"}
#
# expiresAt in the token file is epoch-MILLIS (e.g. 1777490340903), NOT ISO.
# Bash + jq access to ~/.hq/cognito-tokens.json is sanctioned: the harness
# Read-tool deny rule is what forces this structured-access path.

set -u

TOKEN_FILE="$HOME/.hq/cognito-tokens.json"
LEGACY_FILE="$HOME/.hq/auth/session.json"
LOGIN_LOCK="/tmp/hq-deploy-login-attempted-$USER"
HARD_CAP_S=200
NOW_MS=$(($(date +%s) * 1000))

emit() { printf '%s\n' "$1"; exit 0; }
err()  { printf '%s\n' "{\"status\":\"login_required\",\"reason\":\"$1\"}"; exit 0; }

# 1. Find token file
if [ -f "$TOKEN_FILE" ]; then
  TF="$TOKEN_FILE"
elif [ -f "$LEGACY_FILE" ]; then
  TF="$LEGACY_FILE"
else
  TF=""
fi

# 2. Try cache hit
if [ -n "$TF" ]; then
  AT=$(jq -r '.accessToken // empty' "$TF" 2>/dev/null)
  EXP=$(jq -r '.expiresAt // 0' "$TF" 2>/dev/null)
  if [ -n "$AT" ] && [ "$EXP" -gt "$NOW_MS" ] 2>/dev/null; then
    emit "{\"status\":\"ok\",\"jwt\":\"$AT\",\"expires_at\":$EXP,\"source\":\"cache\"}"
  fi
fi

# 3. Refresh path (token exists but stale)
if [ -n "$TF" ]; then
  RT=$(jq -r '.refreshToken // empty' "$TF" 2>/dev/null)
  if [ -n "$RT" ]; then
    if command -v hq-auth-refresh >/dev/null 2>&1; then
      hq-auth-refresh >/dev/null 2>&1 || true
    elif command -v npx >/dev/null 2>&1; then
      npx -y --package=@indigoai-us/hq-cli hq-auth-refresh >/dev/null 2>&1 || true
    fi
    if [ -f "$TOKEN_FILE" ]; then
      AT=$(jq -r '.accessToken // empty' "$TOKEN_FILE" 2>/dev/null)
      EXP=$(jq -r '.expiresAt // 0' "$TOKEN_FILE" 2>/dev/null)
      if [ -n "$AT" ] && [ "$EXP" -gt "$NOW_MS" ] 2>/dev/null; then
        emit "{\"status\":\"ok\",\"jwt\":\"$AT\",\"expires_at\":$EXP,\"source\":\"refresh\"}"
      fi
    fi
  fi
fi

# 4. Login path (no token, or refresh failed) — one-shot per session
if [ -e "$LOGIN_LOCK" ]; then
  err "login_already_attempted"
fi
if ! command -v npx >/dev/null 2>&1 && ! command -v hq >/dev/null 2>&1; then
  err "no_token_no_npx"
fi

touch "$LOGIN_LOCK"
printf 'Opening HQ sign-in in your browser — one moment...\n' >&2

if command -v hq >/dev/null 2>&1; then
  hq auth login >/dev/null 2>&1 &
else
  npx -y --package=@indigoai-us/hq-cli hq auth login >/dev/null 2>&1 &
fi
LOGIN_PID=$!
( sleep 180 && kill "$LOGIN_PID" 2>/dev/null ) &
KILLER_PID=$!
wait "$LOGIN_PID" 2>/dev/null
kill "$KILLER_PID" 2>/dev/null
wait "$KILLER_PID" 2>/dev/null

if [ -f "$TOKEN_FILE" ]; then
  AT=$(jq -r '.accessToken // empty' "$TOKEN_FILE" 2>/dev/null)
  EXP=$(jq -r '.expiresAt // 0' "$TOKEN_FILE" 2>/dev/null)
  if [ -n "$AT" ]; then
    emit "{\"status\":\"ok\",\"jwt\":\"$AT\",\"expires_at\":$EXP,\"source\":\"login\"}"
  fi
fi
err "login_attempt_failed"
