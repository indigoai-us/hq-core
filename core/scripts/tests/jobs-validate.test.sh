#!/usr/bin/env bash
# hq-core: public
# Regression: jobs-validate.sh against Outpost scheduled job fixtures (US-002).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VALIDATE="$ROOT/core/scripts/jobs-validate.sh"
FIX="$ROOT/core/scripts/tests/fixtures/jobs"

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[ -f "$VALIDATE" ] || { echo "FAIL: missing $VALIDATE" >&2; exit 1; }
[ -x "$VALIDATE" ] || chmod +x "$VALIDATE"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

echo "[1] valid fixtures exit 0"
rc=0
out="$("$VALIDATE" "$FIX/valid" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "valid dir expected 0, got $rc :: $out"
pass "valid/ (≥3 jobs including requirements + informational pending_probe)"

echo "[2] each invalid fixture exits non-zero with field name"
declare -a CASES=(
  "missing-required.yaml:exec"
  "bad-cron.yaml:schedule"
  "unknown-runtime.yaml:runtime"
  "timeout-out-of-range.yaml:timeout_seconds"
  "unknown-requirements-key.yaml:requirements.mcp_servers"
  "inline-secret-in-requirements.yaml:requirements.secrets"
  "nl-schedule.yaml:schedule"
  "cwd-absolute.yaml:requirements.cwd"
  "cwd-dotdot.yaml:requirements.cwd"
  "bad-surface.yaml:exec.surface"
)
for case in "${CASES[@]}"; do
  file="${case%%:*}"
  field="${case#*:}"
  rc=0
  err="$("$VALIDATE" "$FIX/invalid/$file" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "$file expected non-zero"
  echo "$err" | grep -q "$field" || fail "$file stderr should name '$field': $err"
  pass "$file -> non-zero naming $field"
done

echo "[3] e2e AC: gemini runtime names field"
rc=0
err="$("$VALIDATE" "$FIX/invalid/unknown-runtime.yaml" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "gemini should fail"
echo "$err" | grep -qi "runtime" || fail "should name runtime: $err"
echo "$err" | grep -qi "gemini" || fail "should mention gemini: $err"
pass "unknown runtime gemini"

echo "[4] e2e AC: secret value under requirements.secrets"
rc=0
err="$("$VALIDATE" "$FIX/invalid/inline-secret-in-requirements.yaml" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "inline secret should fail"
echo "$err" | grep -qi "requirements.secrets" || fail "should name requirements.secrets: $err"
pass "inline secret rejected"

echo "[5] duplicate id across files"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/jobs-validate-dup.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cp "$FIX/valid/personal-daily-digest.yaml" "$tmp/a.yaml"
cp "$FIX/valid/personal-daily-digest.yaml" "$tmp/b.yaml"
rc=0
err="$("$VALIDATE" "$tmp/a.yaml" "$tmp/b.yaml" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "duplicate id should fail"
echo "$err" | grep -qi "duplicate" || fail "should say duplicate: $err"
pass "duplicate id"

echo "[6] single valid personal job with requirements exits 0"
rc=0
"$VALIDATE" "$FIX/valid/company-with-requirements.yaml" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "company-with-requirements should pass"
pass "requirements block valid"

echo "[7] exec.surface remote is valid"
rc=0
"$VALIDATE" "$FIX/valid/remote-surface.yaml" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "remote-surface should pass"
pass "exec.surface=remote valid"

echo "PASS: jobs-validate"
