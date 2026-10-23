#!/usr/bin/env bash
# Regression coverage for leak-scan report-only mode. Content scans run in CI
# with --warn: findings print as ::warning:: lines and the scan exits 0.
# Without --warn the same finding still exits 1, and a usage error still
# exits 2 in either mode.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCAN="$ROOT/.leak-scan/scan.sh"
WF="$ROOT/.github/workflows/pr-checks.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

FX="$TMP/repo"
mkdir -p "$FX/.leak-scan" "$FX/core/scripts"
cp "$SCAN" "$FX/.leak-scan/scan.sh"
git -C "$FX" init -q
git -C "$FX" config user.email test@example.com
git -C "$FX" config user.name t
printf 'echo ok\n' > "$FX/core/scripts/clean.sh"
git -C "$FX" add -A
git -C "$FX" commit -qm clean

# Clean tree: both modes pass.
(cd "$FX" && bash .leak-scan/scan.sh users-path >/dev/null 2>&1) || fail "clean tree failed in blocking mode"
(cd "$FX" && bash .leak-scan/scan.sh users-path --warn >/dev/null 2>&1) || fail "clean tree failed in warn mode"

# Dirty tree: a home-dir path, assembled so this file does not trip the scan.
home_prefix="/Us""ers"
printf 'cat %s/someone/file\n' "$home_prefix" > "$FX/core/scripts/dirty.sh"
git -C "$FX" add -A
git -C "$FX" commit -qm dirty

set +e
(cd "$FX" && bash .leak-scan/scan.sh users-path >/dev/null 2>&1); rc_block=$?
out="$(cd "$FX" && bash .leak-scan/scan.sh users-path --warn 2>&1)"; rc_warn=$?
out_env="$(cd "$FX" && HQ_SCAN_MODE=warn bash .leak-scan/scan.sh users-path 2>&1)"; rc_env=$?
(cd "$FX" && bash .leak-scan/scan.sh no-such-mode --warn >/dev/null 2>&1); rc_bad=$?
set -e

[[ $rc_block -eq 1 ]] || fail "blocking mode must exit 1 on a finding (got $rc_block)"
[[ $rc_warn -eq 0 ]] || fail "--warn must exit 0 on a finding (got $rc_warn)"
[[ $rc_env -eq 0 ]] || fail "HQ_SCAN_MODE=warn must exit 0 on a finding (got $rc_env)"
grep -q '::warning::.*dirty.sh' <<<"$out" || fail "--warn must print the finding as ::warning::"
if grep -q '::error::' <<<"$out"; then fail "--warn must not print ::error::"; fi
grep -q '::warning::.*dirty.sh' <<<"$out_env" || fail "HQ_SCAN_MODE=warn must print the finding"
# Structural modes ignore warn mode: settings-local-not-ignored still fails.
printf '.claude/settings.local.json\n' > "$FX/.gitignore"
git -C "$FX" add -A
git -C "$FX" commit -qm ignore
set +e
(cd "$FX" && HQ_SCAN_MODE=warn bash .leak-scan/scan.sh settings-local-not-ignored --warn >/dev/null 2>&1); rc_struct=$?
set -e
[[ $rc_struct -eq 1 ]] || fail "structural modes must not be softened by warn mode (got $rc_struct)"
[[ $rc_bad -eq 2 ]] || fail "unknown mode must still exit 2 under --warn (got $rc_bad)"

# CI wiring: every content scan runs report-only.
for m in denylist policy-rationale users-path provenance vendor-public-ok public-frontmatter; do
  grep -qE "run: bash \.leak-scan/scan\.sh $m --warn$" "$WF" || fail "pr-checks.yml must run '$m' with --warn"
done

echo "PASS: leak-scan warn mode (findings warn and exit 0; blocking mode and script errors unchanged; CI content scans report-only)"
