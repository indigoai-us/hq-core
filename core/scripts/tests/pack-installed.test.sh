#!/usr/bin/env bash
# Regression coverage for core/scripts/pack-installed.sh — the canonical
# "is this hq pack installed?" check behind pack-aware skill output (/plan
# Step 9 must not present /run-project as runnable on a pack-less install —
# the DEV-1716 "Unknown command: /run-project" dead-end). Asserts the marker
# is core/packages/<pack>/package.yaml (same as scan-packages.sh), a bare
# pack dir without a manifest does NOT count, and usage errors exit 2.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

SCRIPT="${ROOT}/core/scripts/pack-installed.sh"
[[ -f "$SCRIPT" ]] || fail "pack-installed.sh not found at $SCRIPT"

HQ="${TMP}/HQ"
mkdir -p "${HQ}/core/packages"

run_check() { # run_check [args...] -> echoes exit code, output in out.log
  local rc=0
  HQ_ROOT="$HQ" bash "$SCRIPT" "$@" > "${TMP}/out.log" 2>&1 || rc=$?
  echo "$rc"
}

# --- Case A: pack absent -> exit 1 -------------------------------------------
rc="$(run_check hq-pack-engineering --explain)"
[[ "$rc" == "1" ]] || fail "Case A: expected exit 1 for absent pack, got $rc"
grep -q "not installed" "${TMP}/out.log" || fail "Case A: --explain should say not installed"
grep -q "hq install github:indigoai-us/hq-packages#packages/hq-pack-engineering" "${TMP}/out.log" \
  || fail "Case A: --explain should print the pack's install line"

# --- Case B: pack dir WITHOUT package.yaml -> still exit 1 -------------------
# (scan-packages.sh skips manifest-less dirs; so must this check)
mkdir -p "${HQ}/core/packages/hq-pack-engineering"
rc="$(run_check hq-pack-engineering)"
[[ "$rc" == "1" ]] || fail "Case B: expected exit 1 for manifest-less pack dir, got $rc"

# --- Case C: manifest present -> exit 0 --------------------------------------
echo "name: hq-pack-engineering" > "${HQ}/core/packages/hq-pack-engineering/package.yaml"
rc="$(run_check hq-pack-engineering)"
[[ "$rc" == "0" ]] || fail "Case C: expected exit 0 for installed pack, got $rc"
rc="$(run_check hq-pack-engineering --explain)"
[[ "$rc" == "0" ]] || fail "Case C: expected exit 0 with --explain, got $rc"
grep -q "installed: hq-pack-engineering" "${TMP}/out.log" || fail "Case C: --explain should say installed"

# --- Case D: other pack still absent -> exit 1 --------------------------------
rc="$(run_check hq-pack-does-not-exist)"
[[ "$rc" == "1" ]] || fail "Case D: expected exit 1 for a different absent pack, got $rc"

# --- Case E: usage errors -> exit 2 -------------------------------------------
rc="$(run_check)"
[[ "$rc" == "2" ]] || fail "Case E: expected exit 2 with no pack name, got $rc"
rc="$(run_check one two)"
[[ "$rc" == "2" ]] || fail "Case E: expected exit 2 with two pack names, got $rc"
rc="$(run_check --bogus hq-pack-engineering)"
[[ "$rc" == "2" ]] || fail "Case E: expected exit 2 on unknown flag, got $rc"

echo "PASS: pack-installed (absent -> manifest-less dir -> installed -> usage)"
