#!/usr/bin/env bash
# identity-resolve.sh — resolve a Cognito access token (JWT) for hq-deploy.
# Inlined replacement for the former Identity sub-agent: same JSON contract,
# zero Task-tool overhead, deterministic.
#
# Output (one JSON line on stdout):
#   {"status":"ok","jwt":"...","id_token":"...","expires_at":<epoch-ms>,"source":"cache|refresh|login"}
#
# `id_token` is the HQ Pro / grantee-validation token (X-HQ-Pro-Authorization).
# Callers MUST take it from here rather than re-reading the token file with a
# raw `jq`: only this script applies the expiry skew and the refresh path, so a
# raw read silently reintroduces the mid-deploy 401 this script exists to stop.
#   {"status":"login_required","reason":"<short>"}
#   {"status":"missing_dependency","dep":"jq|node","install":"<per-OS guidance>"}
#
# JSON field extract: jq preferred, then node via core/scripts/hook-lib.sh
# (hq_json_get). Do not reimplement a second JSON engine here.
# expiresAt in the token file is epoch-MILLIS (e.g. 1777490340903), NOT ISO.
# Bash access to ~/.hq/cognito-tokens.json is sanctioned: the harness
# Read-tool deny rule is what forces this structured-access path.

set -u

# bash 3.2-safe SCRIPT_DIR (no external dirname)
_src="${BASH_SOURCE[0]}"
_dir="${_src%/*}"
[ "$_dir" = "$_src" ] && _dir="."
SCRIPT_DIR="$(cd "$_dir" && pwd)"

# Walk up from this script to find HQ root (contains core/scripts/hook-lib.sh).
_find_hook_lib() {
  local d="$SCRIPT_DIR"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/core/scripts/hook-lib.sh" ]; then
      printf '%s\n' "$d/core/scripts/hook-lib.sh"
      return 0
    fi
    case "$d" in
      */*) d="${d%/*}" ;;
      *) break ;;
    esac
  done
  return 1
}

TOKEN_FILE="$HOME/.hq/cognito-tokens.json"
LEGACY_FILE="$HOME/.hq/auth/session.json"
DEPLOY_USER_KEY=${USER:-${USERNAME:-unknown}}
DEPLOY_USER_KEY=${DEPLOY_USER_KEY//[^[:alnum:]_.-]/_}
_DEPLOY_TMPDIR="${TMPDIR:-/tmp}"
_DEPLOY_TMPDIR="${_DEPLOY_TMPDIR%/}"
LOGIN_LOCK="$_DEPLOY_TMPDIR/hq-deploy-login-attempted-$DEPLOY_USER_KEY"

emit() { printf '%s\n' "$1"; exit 0; }
err()  { printf '%s\n' "{\"status\":\"login_required\",\"reason\":\"$1\"}"; exit 0; }

# Prefer jq; fall back to node. A PATH entry is not proof that node runs:
# Windows app-execution aliases and stale shims may resolve but fail every call.
# Probe execution before allowing hook-lib to select node as its JSON engine.
JQ_OK=0
NODE_OK=0
command -v jq >/dev/null 2>&1 && JQ_OK=1
if command -v node >/dev/null 2>&1 \
  && node -e 'process.exit(0)' >/dev/null 2>&1; then
  NODE_OK=1
fi
if [ "$JQ_OK" -eq 0 ] && [ "$NODE_OK" -eq 0 ]; then
  emit '{"status":"missing_dependency","dep":"jq|node","install":"Install jq or Node.js so /deploy can read the Cognito token file. Windows: winget install jqlang.jq  (or choco install jq / scoop install jq); also winget install OpenJS.NodeJS. macOS: brew install jq node. Linux: sudo apt-get install jq nodejs  (or sudo dnf install jq nodejs)."}'
fi

# Epoch-ms: prefer node (works on PATH-isolated Windows Git Bash), but validate
# its output. A broken node shim must not turn NOW_MS into 0 and make every
# positive expiresAt look current. Fall back to date; fail visibly if neither
# clock source works.
NOW_MS=""
if [ "$NODE_OK" -eq 1 ]; then
  NOW_MS=$(node -e 'process.stdout.write(String(Date.now()))' 2>/dev/null || true)
fi
case "$NOW_MS" in
  ''|0|*[!0-9]*)
    NOW_S=""
    if command -v date >/dev/null 2>&1; then
      NOW_S=$(date +%s 2>/dev/null || true)
    fi
    case "$NOW_S" in
      ''|0|*[!0-9]*)
        emit '{"status":"missing_dependency","dep":"node|date","install":"Install or repair Node.js, or provide a working date command, so /deploy can validate token expiry."}'
        ;;
      *) NOW_MS=$((NOW_S * 1000)) ;;
    esac
    ;;
esac

HOOK_LIB="$(_find_hook_lib || true)"
if [ -z "$HOOK_LIB" ] || [ ! -f "$HOOK_LIB" ]; then
  err "hook_lib_missing"
fi
# shellcheck disable=SC1090
. "$HOOK_LIB"

# Read a top-level string/number field from a token JSON file via hook-lib engine order.
token_field() {
  local file=$1 key=$2
  hq_json_get "$key" < "$file"
}

# 1. Find token file
if [ -f "$TOKEN_FILE" ]; then
  TF="$TOKEN_FILE"
elif [ -f "$LEGACY_FILE" ]; then
  TF="$LEGACY_FILE"
else
  TF=""
fi

# 2. Try cache hit
# A bare "not yet expired" check is not enough: the caller uses this token for
# the WHOLE deploy (build, tarball, S3 upload, then the access-policy call),
# which routinely takes minutes. Accepting a token with seconds of life left
# guarantees a mid-deploy 401 once per token hour. Treat anything inside the
# skew window as stale so the refresh path below runs first.
SKEW_MS=300000  # 5 min — must exceed worst-case deploy duration after this call
if [ -n "$TF" ]; then
  AT=$(token_field "$TF" "accessToken")
  IDT=$(token_field "$TF" "idToken")
  EXP=$(token_field "$TF" "expiresAt")
  [ -n "$EXP" ] || EXP=0
  if [ -n "$AT" ] && [ "$EXP" -gt "$((NOW_MS + SKEW_MS))" ] 2>/dev/null; then
    emit "{\"status\":\"ok\",\"jwt\":\"$AT\",\"id_token\":\"$IDT\",\"expires_at\":$EXP,\"source\":\"cache\"}"
  fi
fi

# 3. Refresh path (token exists but stale)
if [ -n "$TF" ]; then
  RT=$(token_field "$TF" "refreshToken")
  if [ -n "$RT" ]; then
    if command -v hq-auth-refresh >/dev/null 2>&1; then
      hq-auth-refresh >/dev/null 2>&1 || true
    elif command -v npx >/dev/null 2>&1; then
      npx -y --package=@indigoai-us/hq-cli hq-auth-refresh >/dev/null 2>&1 || true
    fi
    if [ -f "$TOKEN_FILE" ]; then
      AT=$(token_field "$TOKEN_FILE" "accessToken")
      IDT=$(token_field "$TOKEN_FILE" "idToken")
      EXP=$(token_field "$TOKEN_FILE" "expiresAt")
      [ -n "$EXP" ] || EXP=0
      # Same skew applies: if hq-auth-refresh silently no-opped, the on-disk
      # token is unchanged and still inside the window. Fall through to login
      # rather than hand the caller a token that dies mid-deploy.
      if [ -n "$AT" ] && [ "$EXP" -gt "$((NOW_MS + SKEW_MS))" ] 2>/dev/null; then
        emit "{\"status\":\"ok\",\"jwt\":\"$AT\",\"id_token\":\"$IDT\",\"expires_at\":$EXP,\"source\":\"refresh\"}"
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
  AT=$(token_field "$TOKEN_FILE" "accessToken")
  IDT=$(token_field "$TOKEN_FILE" "idToken")
  EXP=$(token_field "$TOKEN_FILE" "expiresAt")
  [ -n "$EXP" ] || EXP=0
  if [ -n "$AT" ]; then
    emit "{\"status\":\"ok\",\"jwt\":\"$AT\",\"id_token\":\"$IDT\",\"expires_at\":$EXP,\"source\":\"login\"}"
  fi
fi
err "login_attempt_failed"
