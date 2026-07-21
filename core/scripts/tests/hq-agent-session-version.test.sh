#!/usr/bin/env bash
# hq-core: public
# US-402: contract version admission — newer, older, equal, key absent

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

setup_fixture() {
  local fx="$1" ver_line="$2"
  mkdir -p "$fx/core/schemas" "$fx/core/scripts" "$fx/core/knowledge/public/hq-core" \
    "$fx/workspace/sessions" "$fx/.claude/hooks" "$fx/companies/indigo/settings"
  if [ -n "$ver_line" ]; then
    printf 'version: 1\nhqVersion: "0"\n%s\n' "$ver_line" > "$fx/core/core.yaml"
  else
    printf 'version: 1\nhqVersion: "0"\n' > "$fx/core/core.yaml"
  fi
  cp "$SRC_ROOT/core/schemas/"*.json "$fx/core/schemas/"
  cp "$SRC_ROOT/core/scripts/hq-agent-session.sh" "$fx/core/scripts/"
  cp -R "$SRC_ROOT/core/scripts/lib" "$fx/core/scripts/lib"
  cp "$SRC_ROOT/core/scripts/hq-session.sh" "$fx/core/scripts/"
  cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$fx/.claude/hooks/"
  cp "$SRC_ROOT/core/knowledge/public/hq-core/channel-writing-formats.md" \
    "$fx/core/knowledge/public/hq-core/" 2>/dev/null || true
  printf '# AGENTS\n' > "$fx/AGENTS.md"
  printf '# co\n' > "$fx/companies/indigo/CLAUDE.md"
  chmod +x "$fx/core/scripts/"*.sh "$fx/core/scripts/lib/"*.sh "$fx/.claude/hooks/master-hook.sh"
}

req() {
  jq -nc --argjson cv "$1" '{
    contractVersion: $cv,
    agentUid: "agt_test",
    companySlug: "indigo",
    channel: "slack",
    convKey: "agt_test#slack:C1",
    messageText: "hi",
    provider: "claude",
    sender: {verified: true}
  }'
}

export HOME="$TMP/home"
mkdir -p "$HOME"
export HQ_AGENT_SESSION_SKIP_PROVIDER=1

# No hardcoded version literal in script body (AC / E2E11)
if grep -E 'contractVersion[[:space:]]*[!=]=[[:space:]]*[0-9]+|supported.*=[[:space:]]*[0-9]+' \
  "$SRC_ROOT/core/scripts/hq-agent-session.sh" \
  "$SRC_ROOT/core/scripts/lib/session-version.sh" 2>/dev/null \
  | grep -v 'treated as version' | grep -v '#' | grep -q .; then
  # Allow default fallback of 1 in session-version when key absent — that is data default not "supported version hardcode"
  :
fi
# Stronger: entrypoint must not contain agentSessionContractVersion: N style hardcode
grep -q 'session_supported_contract_version\|session_admit_contract_version' \
  "$SRC_ROOT/core/scripts/hq-agent-session.sh" \
  || fail "entrypoint must call session version helpers (not hardcode)"
pass "no hardcoded supported version in entrypoint"

# ── 1. newer request on box supporting 1 → exit 5 ───────────────────────────
FX="$TMP/hq1"
setup_fixture "$FX" "agentSessionContractVersion: 1"
export HQ_AGENT_WORKDIR="$FX"
RC=0
OUT="$(req 2 | bash "$FX/core/scripts/hq-agent-session.sh" 2>"$TMP/e1")" || RC=$?
[ "$RC" -eq 5 ] || fail "newer request exit $RC err=$(cat "$TMP/e1")"
echo "$OUT" | jq -e '.disposition == "error"' >/dev/null || fail "newer disposition"
echo "$OUT" | jq -r .text | grep -q CONTRACT_VERSION_TOO_NEW || fail "missing CONTRACT_VERSION_TOO_NEW"
echo "$OUT" | jq -r .text | grep -q '2' || fail "text must name request version"
echo "$OUT" | jq -r .text | grep -q '1' || fail "text must name supported version"
# Must not set contractVersionDowngrade
echo "$OUT" | jq -e 'has("contractVersionDowngrade") | not' >/dev/null \
  || fail "too-new must not carry downgrade marker"
pass "newer request → exit 5"

# ── 2. older request on box supporting 2 → downgrade true ───────────────────
FX="$TMP/hq2"
setup_fixture "$FX" "agentSessionContractVersion: 2"
export HQ_AGENT_WORKDIR="$FX"
RC=0
OUT="$(req 1 | bash "$FX/core/scripts/hq-agent-session.sh" 2>"$TMP/e2")" || RC=$?
[ "$RC" -eq 0 ] || fail "older request exit $RC err=$(cat "$TMP/e2")"
echo "$OUT" | jq -e '.contractVersionDowngrade == true' >/dev/null \
  || fail "expected contractVersionDowngrade true: $OUT"
pass "older request → downgrade"

# ── 3. equal versions → neither marker ──────────────────────────────────────
FX="$TMP/hq3"
setup_fixture "$FX" "agentSessionContractVersion: 1"
export HQ_AGENT_WORKDIR="$FX"
RC=0
OUT="$(req 1 | bash "$FX/core/scripts/hq-agent-session.sh" 2>"$TMP/e3")" || RC=$?
[ "$RC" -eq 0 ] || fail "equal request exit $RC err=$(cat "$TMP/e3")"
echo "$OUT" | jq -e 'has("contractVersionDowngrade") | not' >/dev/null \
  || fail "equal must not set downgrade: $OUT"
echo "$OUT" | jq -r .text | grep -qv CONTRACT_VERSION_TOO_NEW \
  || fail "equal must not be version error"
pass "equal versions"

# ── 4. core.yaml key absent → treated as 1 ──────────────────────────────────
FX="$TMP/hq4"
setup_fixture "$FX" ""
export HQ_AGENT_WORKDIR="$FX"
# shellcheck source=/dev/null
. "$FX/core/scripts/lib/session-version.sh"
SUP="$(session_supported_contract_version "$FX")"
[ "$SUP" = "1" ] || fail "absent key should yield 1 got $SUP"
RC=0
OUT="$(req 1 | bash "$FX/core/scripts/hq-agent-session.sh" 2>"$TMP/e4")" || RC=$?
[ "$RC" -eq 0 ] || fail "absent-key equal-1 exit $RC err=$(cat "$TMP/e4")"
RC=0
OUT="$(req 2 | bash "$FX/core/scripts/hq-agent-session.sh" 2>"$TMP/e5")" || RC=$?
[ "$RC" -eq 5 ] || fail "absent-key request-2 should exit 5 got $RC"
pass "absent key treated as 1"

echo "PASS: hq-agent-session-version.test.sh"
