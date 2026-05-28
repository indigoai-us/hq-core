#!/usr/bin/env bash
# Regression coverage for the v15.0.0 hq-pack-engineering force-install contract:
# scan-packages.sh must (a) refuse to clobber an inline copy still present at a
# bare-name target, (b) symlink the pack contribution once the inline copy is
# removed, and (c) be an idempotent no-op on re-run. This is the seam /update-hq
# Phase 5d-PRE / 5d / 5d-POST depend on.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

HQ_ROOT="${TMP}/HQ"
PKG="${HQ_ROOT}/core/packages/hq-pack-engineering"
mkdir -p \
  "${PKG}/skills/tdd" \
  "${PKG}/workers/qa-tester" \
  "${PKG}/policies" \
  "${HQ_ROOT}/.claude/skills" \
  "${HQ_ROOT}/core/workers/public" \
  "${HQ_ROOT}/core/policies"

# Minimal pack payload + manifest (contributes a skill, a worker, a policy).
echo "tdd skill" > "${PKG}/skills/tdd/SKILL.md"
echo "qa worker" > "${PKG}/workers/qa-tester/worker.yaml"
echo "e2e policy" > "${PKG}/policies/e2e-testing-standards.md"
cat > "${PKG}/package.yaml" <<'YAML'
name: hq-pack-engineering
version: 1.2.0
publisher: '@indigoai-us'
access: public
contributes:
  skills:
    - tdd
  workers:
    - qa-tester
  policies:
    - e2e-testing-standards
YAML

run_scan() { ( cd "${HQ_ROOT}" && HQ_ROOT="${HQ_ROOT}" HQ_SCAN_QUIET=1 bash "${ROOT}/core/scripts/scan-packages.sh" ) ; }

# --- Case A: inline copy present -> collision, host content wins (no symlink) ---
mkdir -p "${HQ_ROOT}/.claude/skills/tdd"
echo "INLINE (user copy)" > "${HQ_ROOT}/.claude/skills/tdd/SKILL.md"
warn_out="$(run_scan 2>&1 1>/dev/null || true)"
echo "${warn_out}" | grep -qi 'collision\|host content wins\|skipping' \
  || fail "Case A: expected a collision/host-wins warning, got: ${warn_out}"
[[ -L "${HQ_ROOT}/.claude/skills/tdd" ]] && fail "Case A: tdd became a symlink despite inline copy present"
grep -q "INLINE" "${HQ_ROOT}/.claude/skills/tdd/SKILL.md" || fail "Case A: inline copy was clobbered"

# --- Case B: remove inline copy -> scan symlinks bare-name path into the pack ---
rm -rf "${HQ_ROOT}/.claude/skills/tdd"
run_scan >/dev/null 2>&1 || fail "Case B: scan-packages exited non-zero"
[[ -L "${HQ_ROOT}/.claude/skills/tdd" ]] || fail "Case B: tdd did not become a symlink"
tgt="$(readlink "${HQ_ROOT}/.claude/skills/tdd")"
echo "${tgt}" | grep -q 'core/packages/hq-pack-engineering/skills/tdd' \
  || fail "Case B: tdd symlink points at '${tgt}', expected the pack"
[[ -L "${HQ_ROOT}/core/workers/public/qa-tester" ]] || fail "Case B: qa-tester worker not symlinked"

# --- Case C: re-run is an idempotent no-op (still a symlink, still exit 0) ---
run_scan >/dev/null 2>&1 || fail "Case C: re-run exited non-zero"
[[ -L "${HQ_ROOT}/.claude/skills/tdd" ]] || fail "Case C: tdd symlink lost on re-run"

echo "PASS: scan-packages-engineering (collision -> remove -> symlink -> idempotent)"
