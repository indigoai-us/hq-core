#!/usr/bin/env bash
# identity-resolve-missing-jq.test.sh — node fallback + missing_dependency.
# (a) PATH without jq but with node + valid token → status=ok
# (b) PATH without jq and without node → status=missing_dependency (not login_required)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$SCRIPT_DIR/identity-resolve.sh"
SKILL="$SCRIPT_DIR/../SKILL.md"
FAIL=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

HOST_JQ=$(command -v jq 2>/dev/null || true)
HOST_NODE=$(command -v node 2>/dev/null || true)

if [ -z "$HOST_JQ" ]; then
  echo "SKIP: host needs jq to assert fixtures"
  exit 0
fi

FUTURE_MS=$((($(date +%s) + 3600) * 1000))
HOME_A="$TMP/home-a"
mkdir -p "$HOME_A/.hq"
printf '{"accessToken":"node-fallback.jwt","expiresAt":%s}\n' "$FUTURE_MS" \
  > "$HOME_A/.hq/cognito-tokens.json"

# Restricted PATH: only node (no system dirs → no jq). Node is used for epoch too.
BIN_NODE="$TMP/bin-node"
mkdir -p "$BIN_NODE"
if [ -n "$HOST_NODE" ]; then
  ln -sf "$HOST_NODE" "$BIN_NODE/node"
  # Native Windows node.exe may need its install dir for side-by-side DLLs.
  case "$HOST_NODE" in
    *.exe|*.EXE)
      NODE_DIR="${HOST_NODE%/*}"
      [ -n "$NODE_DIR" ] && [ -d "$NODE_DIR" ] && PATH_EXTRA=":$NODE_DIR" || PATH_EXTRA=""
      ;;
    *) PATH_EXTRA="" ;;
  esac
fi

if [ -z "$HOST_NODE" ]; then
  fail "host needs node to run node-fallback case"
else
  OUTPUT=$(PATH="$BIN_NODE$PATH_EXTRA" HOME="$HOME_A" USER=testuser \
    TMPDIR="${TMPDIR:-/tmp}" \
    /bin/bash "$RESOLVER" 2>"$TMP/a.err")
  STATUS=$?
  if [ "$STATUS" = "0" ] && printf '%s\n' "$OUTPUT" | "$HOST_JQ" -e \
    --argjson expires "$FUTURE_MS" \
    '.status == "ok" and .jwt == "node-fallback.jwt" and .expires_at == $expires and .source == "cache"' >/dev/null 2>&1; then
    pass "no jq + node + valid token → status=ok (node path)"
  else
    fail "no jq + node should return ok via node fallback (got: $OUTPUT; err=$(cat "$TMP/a.err" 2>/dev/null))"
  fi
  if printf '%s\n' "$OUTPUT" | grep -q 'login_required'; then
    fail "node fallback must not emit login_required"
  else
    pass "node fallback is not login_required"
  fi
fi

# (b) no jq, no node — empty PATH (engine probe only; no token read)
BIN_NONE="$TMP/bin-none"
mkdir -p "$BIN_NONE"

HOME_B="$TMP/home-b"
mkdir -p "$HOME_B/.hq"
printf '{"accessToken":"should-not-read.jwt","expiresAt":%s}\n' "$FUTURE_MS" \
  > "$HOME_B/.hq/cognito-tokens.json"

OUTPUT=$(PATH="$BIN_NONE" HOME="$HOME_B" USER=testuser \
  TMPDIR="${TMPDIR:-/tmp}" \
  /bin/bash "$RESOLVER" 2>"$TMP/b.err")
STATUS=$?

if [ "$STATUS" = "0" ] && printf '%s\n' "$OUTPUT" | "$HOST_JQ" -e \
  '.status == "missing_dependency" and (.dep | test("jq")) and (.dep | test("node")) and (.install | length > 0)' >/dev/null 2>&1; then
  pass "no jq + no node → status=missing_dependency with install guidance"
else
  fail "expected missing_dependency JSON (got: $OUTPUT; err=$(cat "$TMP/b.err" 2>/dev/null))"
fi

if printf '%s\n' "$OUTPUT" | grep -q 'login_required'; then
  fail "missing engines must not emit login_required"
else
  pass "missing engines is not login_required"
fi

if printf '%s\n' "$OUTPUT" | grep -q 'should-not-read.jwt'; then
  fail "must not echo JWT when engines missing"
else
  pass "no JWT echoed when engines missing"
fi

# The parent deploy recipe must not immediately reintroduce a bare-jq failure
# after identity-resolve successfully uses node. A.3 parses via hook-lib.
if grep -q 'IDENTITY_STATUS=$(printf.*hq_json_get status)' "$SKILL" \
  && grep -q '^\. core/scripts/hook-lib.sh$' "$SKILL"; then
  pass "deploy A.3 parses identity through shared jq-to-node helper"
else
  fail "deploy A.3 must use hook-lib hq_json_get for identity status"
fi

if grep -q 'IDENTITY_STATUS=$(echo.*jq -r' "$SKILL"; then
  fail "deploy A.3 still parses identity status with bare jq"
else
  pass "deploy A.3 has no bare-jq identity status parse"
fi

if grep -q '! "$HQ_LIB_NODE" -e '\''process.exit(0)'\''' "$SKILL"; then
  pass "deploy A.3 probes node execution before JSON fallback"
else
  fail "deploy A.3 must reject broken node shims before hq_json_get"
fi

# (c) broken node + working jq/date: clock must fall back to date. An expired
# token must not be accepted as a cache hit due to NOW_MS=0.
BIN_BROKEN_NODE="$TMP/bin-broken-node"
mkdir -p "$BIN_BROKEN_NODE"
printf '#!/bin/bash\nexit 127\n' > "$BIN_BROKEN_NODE/node"
chmod +x "$BIN_BROKEN_NODE/node"
for tool in jq date; do
  tool_path=$(command -v "$tool" 2>/dev/null || true)
  if [ -n "$tool_path" ]; then
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$tool_path" > "$BIN_BROKEN_NODE/$tool"
    chmod +x "$BIN_BROKEN_NODE/$tool"
  fi
done

HOME_C="$TMP/home-c"
mkdir -p "$HOME_C/.hq"
printf '{"accessToken":"expired.jwt","expiresAt":1}\n' > "$HOME_C/.hq/cognito-tokens.json"
LOCK_C="${TMPDIR:-/tmp}/hq-deploy-login-attempted-testuser"
touch "$LOCK_C"
OUTPUT=$(PATH="$BIN_BROKEN_NODE" HOME="$HOME_C" USER=testuser \
  TMPDIR="${TMPDIR:-/tmp}" \
  /bin/bash "$RESOLVER" 2>"$TMP/c.err")
rm -f "$LOCK_C"

if printf '%s\n' "$OUTPUT" | "$HOST_JQ" -e \
  '.status == "login_required" and .reason == "login_already_attempted"' >/dev/null 2>&1; then
  pass "broken node falls back to date; expired token is rejected"
else
  fail "broken node must not make expired token valid (got: $OUTPUT)"
fi

if printf '%s\n' "$OUTPUT" | grep -q '"status":"ok"'; then
  fail "expired token was accepted after broken node clock"
else
  pass "broken node clock never returns expired JWT"
fi

# (d) no jq + broken node: command -v alone is insufficient. Return a missing
# dependency verdict before hook-lib can select the unusable node engine.
BIN_BROKEN_ONLY="$TMP/bin-broken-only"
mkdir -p "$BIN_BROKEN_ONLY"
printf '#!/bin/bash\nexit 127\n' > "$BIN_BROKEN_ONLY/node"
chmod +x "$BIN_BROKEN_ONLY/node"
date_path=$(command -v date 2>/dev/null || true)
if [ -n "$date_path" ]; then
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$date_path" > "$BIN_BROKEN_ONLY/date"
  chmod +x "$BIN_BROKEN_ONLY/date"
fi

OUTPUT=$(PATH="$BIN_BROKEN_ONLY" HOME="$HOME_A" USER=testuser \
  TMPDIR="${TMPDIR:-/tmp}" \
  /bin/bash "$RESOLVER" 2>"$TMP/d.err")
if printf '%s\n' "$OUTPUT" | "$HOST_JQ" -e \
  '.status == "missing_dependency" and (.dep | test("jq")) and (.dep | test("node"))' >/dev/null 2>&1; then
  pass "no jq + broken node returns missing_dependency"
else
  fail "broken node shim must not be accepted as JSON engine (got: $OUTPUT)"
fi

if printf '%s\n' "$OUTPUT" | grep -q 'login_required'; then
  fail "broken node shim must not degrade to login_required"
else
  pass "broken node shim never triggers login path"
fi

if [ "$FAIL" = "0" ]; then echo "ALL PASS"; exit 0; else echo "FAILURES"; exit 1; fi
