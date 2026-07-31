#!/usr/bin/env bash
# Regression tests for export-skill-catalog.sh

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
EXPORTER="$ROOT/core/scripts/export-skill-catalog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

write_skill() {
  local dir="$1" name="$2" description="$3"
  mkdir -p "$dir"
  cat >"$dir/SKILL.md" <<EOF
---
name: $name
description: $description
---

body
EOF
}

scaffold_hq() {
  local root="$1"
  mkdir -p "$root/.claude/skills" "$root/companies/demo/skills" "$root/core/packages/hq-pack-engineering/skills"
}

echo "[1] company skills shadow root names in exported catalog"
HQ="$TMP/hq-shadow"
scaffold_hq "$HQ"
write_skill "$HQ/companies/demo/skills/startwork" startwork "company copy"
write_skill "$HQ/.claude/skills/startwork" startwork "root copy"
out="$(bash "$EXPORTER" --root "$HQ" --company demo)"
printf '%s\n' "$out" | grep -Fq '/startwork — company copy' || fail "company skill missing: $out"
printf '%s\n' "$out" | grep -Fq 'root copy' && fail "root shadow should not appear: $out"
pass "company precedence honored"

echo "[2] root and package skills export when present"
HQ="$TMP/hq-mix"
scaffold_hq "$HQ"
write_skill "$HQ/.claude/skills/handoff" handoff "wrap sessions"
write_skill "$HQ/core/packages/hq-pack-engineering/skills/land" land "ship code"
out="$(bash "$EXPORTER" --root "$HQ" --company demo)"
printf '%s\n' "$out" | grep -Fq '/handoff — wrap sessions' || fail "root skill missing: $out"
printf '%s\n' "$out" | grep -Fq '/land — ship code' || fail "package skill missing: $out"
pass "root and package skills export"

echo "[3] missing args fail clearly"
set +e
out_missing="$(bash "$EXPORTER" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "expected failure without args"
printf '%s\n' "$out_missing" | grep -Fq -- '--root is required' || fail "missing --root message absent: $out_missing"
pass "usage guardrails"

echo "[4] traversal slug rejected before catalog build"
HQ="$TMP/hq-traversal"
mkdir -p "$HQ/companies/demo/skills" "$HQ/companies/secret/skills" "$HQ/.claude/skills"
write_skill "$HQ/companies/demo/skills/a" a "demo skill"
write_skill "$HQ/companies/secret/skills/b" b "secret skill"
set +e
err="$(bash "$EXPORTER" --root "$HQ" --company 'demo/../secret' 2>&1)"
rc=$?
set -e
[ "$rc" -eq 6 ] || fail "traversal slug expected exit 6 got $rc: $err"
printf '%s\n' "$err" | grep -Fq 'company refused' || fail "expected company refused: $err"
pass "traversal slug rejected"

echo "export-skill-catalog tests passed"
