#!/usr/bin/env bash
# Regression tests for the runtime-independent HQ hook-health checker.
#
# DEV-1942: Claude Desktop and SDK sessions can silently skip every project
# hook when settings.json is missing or project settings are not loaded. The
# checker must detect that condition without depending on those hooks.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CHECKER="$ROOT/core/scripts/check-hq-hooks.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

run_expect() {
  local expected="$1" root="$2" output rc
  set +e
  output="$(bash "$CHECKER" --root "$root" "${@:3}" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq "$expected" ] || fail "expected exit $expected, got $rc: $output"
  printf '%s' "$output"
}

make_healthy_root() {
  local root="$1"
  mkdir -p "$root/.claude"
  cat >"$root/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "echo session-start"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "echo pre-tool"}]}]
  }
}
JSON
}

echo "[1] a healthy project configuration passes without relying on hooks"
HEALTHY="$TMP/healthy"
make_healthy_root "$HEALTHY"
out="$(run_expect 0 "$HEALTHY")"
printf '%s' "$out" | grep -Fq 'HQ hook health: PASS' || fail "healthy root did not pass: $out"
printf '%s' "$out" | grep -Fq 'ledger: not checked' || fail "default check should not falsely require a fresh-session ledger: $out"
pass "healthy settings pass and fresh installs are not falsely warned"

echo "[2] a missing settings file produces an actionable desktop/SDK repair"
MISSING="$TMP/missing"
mkdir -p "$MISSING/.claude"
out="$(run_expect 2 "$MISSING")"
printf '%s' "$out" | grep -Fq '.claude/settings.json is missing' || fail "missing settings diagnosis absent: $out"
printf '%s' "$out" | grep -Fq 'settingSources: ["project"]' || fail "SDK settingSources repair absent: $out"
printf '%s' "$out" | grep -Fq 'hq rescue -y --paths .claude' || fail "targeted rescue repair absent: $out"
pass "missing settings fail with a copy-paste remediation"

echo "[3] missing required hook events fail clearly"
NO_START="$TMP/no-start"
mkdir -p "$NO_START/.claude"
cat >"$NO_START/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo pre-tool"}]}]}}
JSON
out="$(run_expect 2 "$NO_START")"
printf '%s' "$out" | grep -Fq 'SessionStart has no command hook' || fail "missing SessionStart diagnosis absent: $out"
pass "missing SessionStart hook fails"

NO_PRE="$TMP/no-pre"
mkdir -p "$NO_PRE/.claude"
cat >"$NO_PRE/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo session-start"}]}]}}
JSON
out="$(run_expect 2 "$NO_PRE")"
printf '%s' "$out" | grep -Fq 'PreToolUse has no command hook' || fail "missing PreToolUse diagnosis absent: $out"
pass "missing PreToolUse hook fails"

echo "[4] malformed JSON fails instead of being treated as hook-ready"
BAD_JSON="$TMP/bad-json"
mkdir -p "$BAD_JSON/.claude"
printf '{not json\n' >"$BAD_JSON/.claude/settings.json"
out="$(run_expect 2 "$BAD_JSON")"
printf '%s' "$out" | grep -Fq 'is not valid JSON' || fail "invalid JSON diagnosis absent: $out"
pass "invalid JSON fails"

echo "[5] ledger verification detects a runtime that never wrote policy state"
LEDGER="$TMP/ledger"
make_healthy_root "$LEDGER"
out="$(run_expect 2 "$LEDGER" --require-ledger)"
printf '%s' "$out" | grep -Fq 'policy-trigger ledger was not found' || fail "missing ledger diagnosis absent: $out"
printf '%s' "$out" | grep -Fq 'HQ runtime enforcement: NOT OBSERVED' \
  || fail "missing ledger did not emit the runtime-off warning: $out"
mkdir -p "$LEDGER/workspace/orchestrator/policy-trigger-state"
: >"$LEDGER/workspace/orchestrator/policy-trigger-state/desktop-session.txt"
out="$(run_expect 0 "$LEDGER" --require-ledger)"
printf '%s' "$out" | grep -Fq 'ledger: present' || fail "present ledger not reported: $out"
printf '%s' "$out" | grep -Fq 'HQ runtime enforcement: OBSERVED' \
  || fail "present ledger did not emit the runtime-on signal: $out"
pass "ledger requirement distinguishes hook-ready from hooks-observed"

echo "[6] session-scoped verification cannot be satisfied by a stale ledger"
out="$(run_expect 2 "$LEDGER" --session-id app-sdk-session)"
printf '%s' "$out" | grep -Fq 'HQ runtime enforcement: NOT OBSERVED' \
  || fail "missing session ledger did not emit runtime-off warning: $out"
: >"$LEDGER/workspace/orchestrator/policy-trigger-state/app-sdk-session.txt"
out="$(run_expect 0 "$LEDGER" --session-id app-sdk-session)"
printf '%s' "$out" | grep -Fq 'session: app-sdk-session' \
  || fail "exact session identity was not reported: $out"
pass "session-scoped ledger check rejects stale evidence"

echo "PASS: hook-health checker"
