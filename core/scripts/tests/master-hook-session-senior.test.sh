#!/usr/bin/env bash
# hq-core: public
# Regression tests for the master-hook.sh session-meta seed of `senior: user`.
#
# hq-session.sh has its own seed (tested in hq-session.test.sh). A test that
# only covers one copy stays green when the other is deleted; both are required
# or hop 2 of the authority walk dies for sessions that took that path.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "missing $MASTER"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

# ── 1. The seed printf itself carries senior: user ──────────────────────────
# Mutation: remove `senior: user` from this printf. An append elsewhere in the
# file must not keep this assertion green.
seed_printf="$(awk '
  /if \[ ! -f "\$META_FILE" \]/ { in_seed=1; print; next }
  in_seed { print }
  in_seed && /> "\$META_FILE"/ { exit }
' "$MASTER")"
printf '%s\n' "$seed_printf" | grep -q 'senior: user' \
  || fail "master-hook meta seed printf is missing senior: user: $seed_printf"
pass "seed printf includes senior: user"

# ── 2. A first hook event writes senior: user into the new meta.yaml ────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/hooks" "$FIX/core/scripts" \
  "$FIX/workspace/sessions"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIX/.claude/hooks/"
chmod +x "$FIX/.claude/hooks/master-hook.sh"

SID="s-senior-seed"
PAYLOAD="$(jq -nc --arg sid "$SID" '{session_id:$sid,hook_event_name:"SessionStart"}')"
rc=0
printf '%s' "$PAYLOAD" \
  | env HQ_HOOK_TIMEOUT_SENTRY=0 CLAUDE_PROJECT_DIR="$FIX" \
    bash "$FIX/.claude/hooks/master-hook.sh" SessionStart \
    >"$TMP/out" 2>"$TMP/err" || rc=$?
[ "$rc" = "0" ] || fail "SessionStart seed: expected exit 0, got $rc stderr=$(cat "$TMP/err")"

META="$FIX/workspace/sessions/$SID/meta.yaml"
[ -f "$META" ] || fail "SessionStart did not create $META"
grep -qx 'senior: user' "$META" \
  || fail "bootstrapped meta.yaml missing senior: user: $(cat "$META")"
grep -q "^session_id: ${SID}$" "$META" \
  || fail "bootstrapped meta.yaml missing session_id"
pass "SessionStart seed writes senior: user"

echo "ALL PASS: master-hook-session-senior"
exit 0
