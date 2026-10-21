#!/usr/bin/env bash
# Tests for worker lookup in core/scripts/pipeline-conductor.sh (find_worker_yaml):
# a worker id resolves by registry id first (core/workers/registry.yaml), then by
# a pack's worker id (core/packages/<pack>/workers), then by directory name. A
# stale unpacked copy of a pack worker that the registry does not list is
# reported and the pack entry is used; a registered core worker keeps its
# registered path. bash 3.2 portable.
#
# Every lookup goes through `classify` on a story that declares code files and
# starts with a verifier: the error names the resolved worker.yaml's role, so
# the role shows which file the conductor picked.
# shellcheck disable=SC2016  # check() evals single-quoted assertions on purpose
set -u
unset PC_WORKERS_ROOT PC_WORKERS_REGISTRY PC_PACKS_ROOT PC_HQ PC_NOW PC_TABLE PC_PARK_CONFIRM HQ_SESSION_ID
HERE="$(cd "$(dirname "$0")" && pwd)"
PC="${PC_UNDER_TEST:-$HERE/../pipeline-conductor.sh}"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pc-worker-lookup.XXXXXX")" && pwd -P)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "PASS: $1"; else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$T/err" "$T/out"; fi; }

# ---- fixture HQ root: PC_WORKERS_ROOT stays unset, so the conductor's defaults apply ----
H="$T/hq"
mkw() { mkdir -p "$H/$1"; printf 'worker:\n  id: %s\n  role: %s\n' "$2" "$3" > "$H/$1/worker.yaml"; }
# registry id dev-qa-tester lives in dev-team/qa-tester; a decoy directory carries the id as its name
mkw core/workers/public/dev-team/qa-tester dev-qa-tester reviewer-registry
mkw core/workers/public/decoy/dev-qa-tester decoy reviewer-dirname
# only a directory name finds this one
mkw core/workers/public/plain-checker plain-checker reviewer-plain
# a pack worker, and a stale unpacked copy of it that the registry does not list
mkw core/packages/test-pack/workers/pack-reviewer pack-reviewer reviewer-pack
mkw core/workers/public/pack-reviewer pack-reviewer reviewer-stale
# a worker the release ships under core/workers and registers there, with a pack copy of the same id
mkw core/packages/test-pack/workers/shipped-reviewer shipped-reviewer reviewer-shipped-pack
mkw core/workers/public/shipped-reviewer shipped-reviewer reviewer-shipped-core
# a pack worker the registry points at directly: no shadow
mkw core/packages/test-pack/workers/pack-mounted pack-mounted reviewer-mounted
# a pack worker with no registry entry
mkw core/packages/test-pack/workers/only-in-pack only-in-pack reviewer-pack-only
# a registry path outside every worker and pack root is ignored; the directory name wins
mkw elsewhere/outside outside reviewer-outside
mkw core/workers/public/outside outside reviewer-dir-outside
# a company-scoped override of a pack worker is not a stale copy
mkw companies/test-co/workers/_overrides/only-in-pack only-in-pack reviewer-override
mkw core/workers/public/backend-dev backend-dev implementer
cat > "$H/core/workers/registry.yaml" <<'EOF'
# fixture registry
version: "5.0"
workers:
  - id: "dev-qa-tester"
    path: "core/workers/public/dev-team/qa-tester/"
    type: "OpsWorker"
  - id: "shipped-reviewer"
    path: "core/workers/public/shipped-reviewer/"
  - id: "pack-mounted"
    path: "core/packages/test-pack/workers/pack-mounted/"
  - id: "outside"
    path: "elsewhere/outside/"
  - path: "core/workers/public/plain-checker/"
    id: "plain-path-first"
  - id: "backend-dev"
    path: "core/workers/public/backend-dev/"
EOF
export PC_NOW=1790000000 PC_HQ_ROOT="$H"

story() { printf '{"id":"%s","title":"t","passes":false,"dependsOn":[],"files":["src/x.ts"],"worker_preference":["%s","backend-dev"],"acceptanceCriteria":["a"]}' "$1" "$2"; }
{
  printf '{"name":"demo","userStories":[\n'
  story L1 dev-qa-tester; printf ',\n'
  story L2 plain-checker; printf ',\n'
  story L3 pack-reviewer; printf ',\n'
  story L4 pack-mounted; printf ',\n'
  story L5 only-in-pack; printf ',\n'
  story L6 outside; printf ',\n'
  story L7 decoy-missing; printf ',\n'
  story L9 shipped-reviewer; printf ',\n'
  story L10 plain-path-first; printf ',\n'
  printf '{"id":"L8","title":"t","passes":false,"dependsOn":[],"files":["src/y.ts"],"worker_preference":["backend-dev","dev-qa-tester"],"acceptanceCriteria":["a"]}'
  printf '\n]}\n'
} > "$T/prd.json"

run() { "$PC" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
both() { cat "$T/out" "$T/err"; }
cls() { run classify --prd "$T/prd.json" --state "$T/state-$1" --story "$1"; }

# 1. registry id first: dev-qa-tester is dev-team/qa-tester, not the decoy directory named dev-qa-tester
cls L1
check "registry id resolves dev-qa-tester to dev-team/qa-tester" 'both | grep -q "starts with dev-qa-tester (reviewer-registry)"'
check "registry id beats a directory of the same name" '! both | grep -q "reviewer-dirname"'
check "registry lookup: no unknown worker" '! both | grep -q "unknown worker"'
check "registry lookup: no stale warning" '! both | grep -q "stale unpacked copy"'

# 2. directory-name fallback
cls L2
check "directory name finds a worker the registry does not list" 'both | grep -q "starts with plain-checker (reviewer-plain)"'
check "directory fallback: no unknown worker" '! both | grep -q "unknown worker"'

# 3. a stale unpacked copy the registry does not list shadows the pack mount: warn and use the pack entry
cls L3
check "stale copy: warning names the stale directory and the pack" \
  'grep -q "worker pack-reviewer: $H/core/workers/public/pack-reviewer is a stale unpacked copy that shadows the test-pack pack mount and is not in the workers registry; using $H/core/packages/test-pack/workers/pack-reviewer" "$T/err"'
check "stale copy: the warning does not tell the user to delete anything" '! grep -qi "remove\|delete" "$T/err"'
check "stale copy: the pack worker.yaml is used" 'both | grep -q "starts with pack-reviewer (reviewer-pack)"'
check "stale copy: the stale worker.yaml is not used" '! both | grep -q "reviewer-stale"'

# 4. a registry entry that points into the pack is used as is
cls L4
check "registry path into a pack resolves" 'both | grep -q "starts with pack-mounted (reviewer-mounted)"'
check "registry path into a pack: no stale warning" '! both | grep -q "stale unpacked copy"'

# 5. a pack worker id with no registry entry; the _overrides copy is not a stale copy
cls L5
check "pack worker id resolves without a registry entry" 'both | grep -q "starts with only-in-pack (reviewer-pack-only)"'
check "pack worker id: no stale warning" '! both | grep -q "stale unpacked copy"'

# 6. a registry path outside every worker and pack root is ignored
cls L6
check "registry path outside the roots falls back to the directory" 'both | grep -q "starts with outside (reviewer-dir-outside)"'
check "registry path outside the roots is not read" '! both | grep -q "reviewer-outside)"'

# 7. an id that nothing names is still unknown, and the hint lists registry and pack ids
cls L7
check "unknown id: rc 1" '[ "$(cat "$T/rc")" = 1 ]'
check "unknown id is reported" 'both | grep -q "unknown worker decoy-missing"'

# 8. a well-formed story through a registry id classifies cleanly
cls L8
check "implementer-first story with a registry-id verifier: rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "implementer-first story: no unknown worker" '! both | grep -q "unknown worker"'

# 8b. a registered core worker with a pack copy of the same id keeps its registered path, with no warning
cls L9
check "registered core worker beats a pack copy of the same id" 'both | grep -q "starts with shipped-reviewer (reviewer-shipped-core)"'
check "registered core worker: no stale warning" '! both | grep -q "stale unpacked copy"'

# 8c. a registry entry that lists path before id still resolves
cls L10
check "registry entry with path before id resolves" 'both | grep -q "starts with plain-path-first (reviewer-plain)"'

# 9. an explicit PC_WORKERS_ROOT reads no registry or pack: the older directory keying
PC_WORKERS_ROOT="$H/core/workers" "$PC" classify --prd "$T/prd.json" --state "$T/state-x1" --story L1 >"$T/out" 2>"$T/err"
check "explicit PC_WORKERS_ROOT: directory keying finds the decoy" 'both | grep -q "starts with dev-qa-tester (reviewer-dirname)"'

echo "pipeline-worker-lookup: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
