#!/usr/bin/env bash
# hq-core: public
# DEV-1718: scan-packages.sh must detect a worker-id collision and REFUSE to wire
# the pack worker BEFORE creating the symlink. Otherwise a pack whose worker id
# matches a pre-existing host worker (the gemini-coder / gemini-reviewer case)
# silently mints a duplicate id that the registry generator then hard-fails on,
# blocking ALL worker registration. This locks: (a) collision -> loud warn, no
# symlink; (b) a unique-id pack worker IS wired (valid packs unaffected); (c) once
# the clashing host worker is removed, re-running wires the pack worker (and the
# pack's own already-wired symlink is not mistaken for a fresh collision).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

HQ_ROOT="${TMP}/HQ"
PKG="${HQ_ROOT}/core/packages/hq-pack-gemini"
mkdir -p \
  "${PKG}/workers/gemini-coder" \
  "${PKG}/workers/gemini-uniq" \
  "${HQ_ROOT}/core/workers/public/dev-team/gemini-coder"

worker_yaml() { # <path> <id>
  cat > "$1" <<YAML
worker:
  id: $2
  name: "$2"
  description: "test worker"
  type: CodeWorker
  version: "1.0"
YAML
}

# Pre-existing host worker that already claims the id 'gemini-coder'.
worker_yaml "${HQ_ROOT}/core/workers/public/dev-team/gemini-coder/worker.yaml" "gemini-coder"
# Pack worker that COLLIDES on id, plus one with a unique id.
worker_yaml "${PKG}/workers/gemini-coder/worker.yaml" "gemini-coder"
worker_yaml "${PKG}/workers/gemini-uniq/worker.yaml"  "gemini-uniq"

cat > "${PKG}/package.yaml" <<YAML
name: hq-pack-gemini
version: 1.0.0
publisher: '@indigoai-us'
access: public
contributes:
  workers:
    - gemini-coder
    - gemini-uniq
YAML

run_scan() { ( cd "${HQ_ROOT}" && HQ_ROOT="${HQ_ROOT}" HQ_SCAN_QUIET=1 bash "${ROOT}/core/scripts/scan-packages.sh" ) ; }

# --- Case A: id collision -> loud warn, refuse to wire (no symlink) ---
warn_out="$(run_scan 2>&1 1>/dev/null || true)"
printf '%s' "${warn_out}" | grep -qi 'worker-id collision' \
  || fail "Case A: expected a worker-id collision warning, got: ${warn_out}"
printf '%s' "${warn_out}" | grep -q 'gemini-coder' \
  || fail "Case A: collision warning did not name the colliding id; got: ${warn_out}"
[[ -L "${HQ_ROOT}/core/workers/public/gemini-coder" ]] \
  && fail "Case A: colliding pack worker was wired despite the clash (must refuse)"
[[ -e "${HQ_ROOT}/core/workers/public/gemini-coder" ]] \
  && fail "Case A: a gemini-coder target was created at the host bare path (must refuse)"

# --- Case B: unique-id pack worker IS wired (valid packs unaffected) ---
[[ -L "${HQ_ROOT}/core/workers/public/gemini-uniq" ]] \
  || fail "Case B: unique-id pack worker 'gemini-uniq' was not wired"

# --- Case C: remove the clashing host worker -> re-run wires the pack worker,
#             and the pack's own already-wired symlink is not a false collision ---
rm -rf "${HQ_ROOT}/core/workers/public/dev-team/gemini-coder"
run_scan >/dev/null 2>&1 || fail "Case C: scan-packages exited non-zero"
[[ -L "${HQ_ROOT}/core/workers/public/gemini-coder" ]] \
  || fail "Case C: pack worker not wired after the clash was resolved"
# Re-run is idempotent: the existing symlink must NOT be flagged as a self-collision.
warn_out="$(run_scan 2>&1 1>/dev/null || true)"
printf '%s' "${warn_out}" | grep -qi 'worker-id collision' \
  && fail "Case C: pack's own wired symlink was misread as a collision on re-run"
[[ -L "${HQ_ROOT}/core/workers/public/gemini-coder" ]] \
  || fail "Case C: pack worker symlink lost on idempotent re-run"

echo "PASS: scan-packages-id-collision (collision refused -> unique wired -> resolve+idempotent)"
