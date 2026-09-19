#!/usr/bin/env bash
# Regression: active registry rows whose directories are gone must surface
# at SessionStart and must not be treated as available workers.
#
# feedback_a0ca0cb2 / issue 2283: a company tenant listed gtm-depletions-*
# in core/workers/registry.yaml while companies/<slug>/workers/gtm-depletions-*
# did not exist, so the session fell back to a raw ingest script.
#
# Invoked from manifest-nested-parse.test.sh (pr-checks job of the same name).
# Tests here are NOT auto-discovered (indigo-hq-core-staging-pr-mechanics rule 3).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-local-context.sh"
LIB="$ROOT/core/scripts/lib/workers-registry.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$HOOK" ] || fail "inject-local-context.sh not found"
[ -f "$LIB" ] || fail "workers-registry.sh not found"

# shellcheck disable=SC1090
. "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_root() {
  local d="$1"
  mkdir -p "$d/core/workers/public/real" "$d/companies/acme/workers/other-ops"
  cat > "$d/core/workers/public/real/worker.yaml" <<'YAML'
worker:
  id: real
  name: real
  description: Present worker.
  type: OpsWorker
  version: "1.0"
YAML
  cat > "$d/companies/acme/workers/other-ops/worker.yaml" <<'YAML'
worker:
  id: other-ops
  name: other-ops
  description: Present company worker.
  type: OpsWorker
  company: acme
  version: "1.0"
YAML
  cat > "$d/core/workers/registry.yaml" <<'YAML'
version: "5.0"
workers:
  - id: "real"
    path: "core/workers/public/real/"
    type: "OpsWorker"
    status: "active"
  - id: "acme-gtm-depletions-changes-load"
    path: "companies/acme/workers/gtm-depletions-changes-load/"
    type: "OpsWorker"
    company: "acme"
    status: "active"
    description: "Incremental CHANGES load"
  - id: "gtm-depletions-refresh"
    path: "companies/acme/workers/gtm-depletions-refresh/"
    type: "OpsWorker"
    company: "acme"
    status: "active"
  - id: "planned-ghost"
    path: "companies/acme/workers/planned-ghost/"
    type: "OpsWorker"
    status: "planned"
  - id: "other-ops"
    path: "companies/acme/workers/other-ops/"
    type: "OpsWorker"
    company: "acme"
    status: "active"
YAML
}

echo "[1] missing() lists only active rows whose path is gone"
R1="$TMP/r1"
make_root "$R1"
got="$(hq_workers_registry_missing "$R1")"
printf '%s\n' "$got" | grep -Fq 'acme-gtm-depletions-changes-load' \
  || fail "expected changes-load ghost"
printf '%s\n' "$got" | grep -Fq 'gtm-depletions-refresh' \
  || fail "expected refresh ghost"
printf '%s\n' "$got" | grep -Fq 'real' && fail "present core worker listed as missing"
printf '%s\n' "$got" | grep -Fq 'other-ops' && fail "present company worker listed as missing"
printf '%s\n' "$got" | grep -Fq 'planned-ghost' && fail "planned row listed as missing"
pass "active ghosts only"

echo "[2] missing() is silent with no registry"
R2="$TMP/r2"
mkdir -p "$R2"
[ -z "$(hq_workers_registry_missing "$R2")" ] || fail "empty root produced output"
pass "no registry → no output"

echo "[3] SessionStart warns and does not treat ghosts as available"
R3="$TMP/r3"
make_root "$R3"
out=""
rc=0
out="$(CLAUDE_PROJECT_DIR="$R3" bash "$HOOK" 2>&1)" || rc=$?
[ "$rc" = "0" ] || fail "inject-local-context rc=$rc (must stay 0)"
printf '%s\n' "$out" | grep -Fq '<local-context>' || fail "missing local-context"
printf '%s\n' "$out" | grep -Fq 'Missing workers' || fail "no Missing workers warning"
printf '%s\n' "$out" | grep -Fq 'acme-gtm-depletions-changes-load' \
  || fail "warning omitted changes-load id"
printf '%s\n' "$out" | grep -Fq 'gtm-depletions-refresh' \
  || fail "warning omitted refresh id"
printf '%s\n' "$out" | grep -Fq 'do not fall back' \
  || fail "warning omitted fallback instruction"
printf '%s\n' "$out" | grep -Fq 'planned-ghost' && fail "planned ghost in warning"
pass "SessionStart warning names active ghosts"

echo "[4] SessionStart stays quiet when every active path exists"
R4="$TMP/r4"
make_root "$R4"
mkdir -p "$R4/companies/acme/workers/gtm-depletions-changes-load" \
         "$R4/companies/acme/workers/gtm-depletions-refresh"
printf 'worker:\n  id: x\n' > "$R4/companies/acme/workers/gtm-depletions-changes-load/worker.yaml"
printf 'worker:\n  id: y\n' > "$R4/companies/acme/workers/gtm-depletions-refresh/worker.yaml"
out="$(CLAUDE_PROJECT_DIR="$R4" bash "$HOOK" 2>&1)" || rc=$?
[ "$rc" = "0" ] || fail "clean inject-local-context rc=$rc"
printf '%s\n' "$out" | grep -Fq 'Missing workers' && fail "false Missing workers warning"
pass "no warning when paths exist"

echo "[5] directory without worker.yaml still counts as missing"
R5="$TMP/r5"
make_root "$R5"
mkdir -p "$R5/companies/acme/workers/gtm-depletions-changes-load"
got="$(hq_workers_registry_missing "$R5")"
printf '%s\n' "$got" | grep -Fq 'acme-gtm-depletions-changes-load' \
  || fail "empty dir not reported"
pass "missing worker.yaml is missing"

echo "workers-registry-missing tests: ok"
