#!/usr/bin/env bash
# Regression coverage for the hq-pack-engineering auto_install conditional in
# core/core.yaml. The predicate must:
#   - exit non-zero on a greenfield tree (no inline surface) -> auto-install skips
#   - exit zero when a real inline engineering dir exists      -> auto-install fires
#   - exit non-zero when the path is a symlink (already migrated) -> safe no-op
# This is the gate /update-hq Phase 5d-PRE evaluates.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not installed"; exit 0; }

COND="$(yq e '.recommended_packages[] | select(.auto_install == true) | .conditional' "${ROOT}/core/core.yaml")"
[[ -n "${COND}" && "${COND}" != "null" ]] || fail "no auto_install pack with a conditional found in core/core.yaml"

# Predicate must reference both -d and ! -L so already-migrated symlinks are excluded.
echo "${COND}" | grep -q '! -L' || fail "conditional does not guard against symlinks (missing '! -L'): ${COND}"

eval_in() { ( cd "$1" && bash -c "${COND}" >/dev/null 2>&1 ; echo $? ) ; }

# --- greenfield: empty tree -> non-zero (skip) ---
GREEN="${TMP}/green"; mkdir -p "${GREEN}"
[[ "$(eval_in "${GREEN}")" != "0" ]] || fail "greenfield: predicate passed (should skip)"

# --- upgrader: a real inline engineering dir -> zero (install) ---
UP="${TMP}/up"; mkdir -p "${UP}/.claude/skills/tdd"
[[ "$(eval_in "${UP}")" == "0" ]] || fail "upgrader: predicate failed (should fire) with real .claude/skills/tdd"

# --- already-migrated: bare-name path is a symlink -> non-zero (skip) ---
MIG="${TMP}/mig"; mkdir -p "${MIG}/.claude/skills" "${MIG}/pkgtdd"
ln -s "${MIG}/pkgtdd" "${MIG}/.claude/skills/tdd"
[[ "$(eval_in "${MIG}")" != "0" ]] || fail "already-migrated: predicate passed on a symlink (should skip)"

echo "PASS: auto-install-conditional-greenfield (skip greenfield, fire upgrader, skip migrated)"
