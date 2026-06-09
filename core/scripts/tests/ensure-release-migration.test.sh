#!/usr/bin/env bash
# hq-core: public
# Regression coverage for release commits that ship no MIGRATION.md.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="${ROOT}/core/scripts/ensure-release-migration.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail "ensure-release-migration.sh not found at $SRC"

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git config user.name "Test User"
    git config user.email "[EMAIL]"
    mkdir -p core/scripts core/docs/hq .claude
    printf 'hqVersion: "15.0.8"\n' > core/core.yaml
    printf 'old hook\n' > core/scripts/old-hook.sh
    printf '## Release: v15.0.8\n' > core/docs/hq/MIGRATION.md
    printf '{"version":1}\n' > .claude/settings.json
    git add core/core.yaml core/scripts/old-hook.sh core/docs/hq/MIGRATION.md .claude/settings.json
    git commit -qm "base"
  )
}

REPO="${TMP}/repo"
make_repo "$REPO"
OUT="${TMP}/verify.out"

(
  cd "$REPO"
  rm core/docs/hq/MIGRATION.md
  rm core/scripts/old-hook.sh
  printf 'new hook\n' > core/scripts/new-hook.sh
  printf '{"version":2}\n' > .claude/settings.json
)

if (cd "$REPO" && bash "$SRC" --mode verify --version 15.0.9 --base-ref HEAD >"$OUT" 2>&1); then
  fail "verify passed despite a non-trivial diff with no MIGRATION.md"
fi
grep -q 'MIGRATION.md is missing' "$OUT" \
  || fail "missing MIGRATION.md failure did not explain the regression"

(cd "$REPO" && bash "$SRC" --mode generate --version 15.0.9 --base-ref HEAD >/dev/null)

MIG="${REPO}/core/docs/hq/MIGRATION.md"
grep -q '^## Migrating to v15.0.9' "$MIG" || fail "generated migration section missing release header"
grep -q '^### New Files' "$MIG" || fail "generated migration missing New Files section"
grep -q -- '- `core/scripts/new-hook.sh`' "$MIG" || fail "generated migration missing added file path"
grep -q -- '- `.claude/settings.json`' "$MIG" || fail "generated migration missing updated file path"
grep -q -- '- `core/scripts/old-hook.sh`' "$MIG" || fail "generated migration missing removed file path"
! grep -q -- '- `core/docs/hq/MIGRATION.md`' "$MIG" \
  || fail "generated migration must not instruct removal of its own migration doc"
grep -q '^### Migration Steps' "$MIG" || fail "generated migration missing Migration Steps"

(cd "$REPO" && bash "$SRC" --mode verify --version 15.0.9 --base-ref HEAD >/dev/null) \
  || fail "verify failed after generated migration"

BOOKKEEPING="${TMP}/bookkeeping-only"
make_repo "$BOOKKEEPING"
(
  cd "$BOOKKEEPING"
  printf 'hqVersion: "15.0.9"\n' > core/core.yaml
  bash "$SRC" --mode verify --version 15.0.9 --base-ref HEAD >/dev/null
) || fail "bookkeeping-only version bump should not require migration doc"

echo "PASS: ensure-release-migration.sh"
