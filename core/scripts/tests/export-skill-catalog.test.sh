#!/usr/bin/env bash
# Regression tests for export-skill-catalog.sh

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
EXPORTER="$ROOT/core/scripts/export-skill-catalog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

# Match a fixed string inside a captured output without a pipe.
#
# `printf '%s\n' "$out" | grep -Fq ...` looks equivalent but is not: grep -q
# exits the moment it matches, so printf loses its reader and dies of EPIPE
# whenever the matching line is not the last one. Under `set -o pipefail` that
# poisons the pipeline's exit status, and a matching assertion reports a
# failure. It is a race on buffer timing, so it passes locally and fails on CI.
# A here-string has no second process and cannot lose the race.
contains() {
  local needle="$1" haystack="$2"
  grep -Fq -- "$needle" <<<"$haystack"
}

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

write_scalar_skill() {
  local dir="$1" name="$2" marker="$3" continuation="$4"
  mkdir -p "$dir"
  cat >"$dir/SKILL.md" <<EOF
---
name: $name
description: $marker
$continuation
category: following key must not enter the description
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
contains '/startwork — company copy' "$out" || fail "company skill missing: $out"
contains 'root copy' "$out" && fail "root shadow should not appear: $out"
pass "company precedence honored"

echo "[2] root and package skills export when present"
HQ="$TMP/hq-mix"
scaffold_hq "$HQ"
write_skill "$HQ/.claude/skills/handoff" handoff "wrap sessions"
write_skill "$HQ/core/packages/hq-pack-engineering/skills/land" land "ship code"
out="$(bash "$EXPORTER" --root "$HQ" --company demo)"
contains '/handoff — wrap sessions' "$out" || fail "root skill missing: $out"
contains '/land — ship code' "$out" || fail "package skill missing: $out"
pass "root and package skills export"

echo "[3] missing args fail clearly"
set +e
out_missing="$(bash "$EXPORTER" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "expected failure without args"
contains '--root is required' "$out_missing" || fail "missing --root message absent: $out_missing"
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
contains 'company refused' "$err" || fail "expected company refused: $err"
pass "traversal slug rejected"

echo "[5] block-scalar descriptions fold; inline descriptions stay unchanged"
HQ="$TMP/hq-frontmatter-scalars"
scaffold_hq "$HQ"
write_scalar_skill "$HQ/.claude/skills/folded-strip" folded-strip '>-' $'  folded first\n  folded second'
write_scalar_skill "$HQ/.claude/skills/folded-clip" folded-clip '>' $'  clip first\n  clip second'
write_scalar_skill "$HQ/.claude/skills/literal-clip" literal-clip '|' $'  literal first\n  literal second'
write_scalar_skill "$HQ/.claude/skills/literal-strip" literal-strip '|-' $'  strip first\n  strip second'
write_skill "$HQ/.claude/skills/inline" inline 'inline stays exact'
write_skill "$HQ/.claude/skills/quoted-inline" quoted-inline '"quoted stays exact"'
out="$(bash "$EXPORTER" --root "$HQ" --company demo)"
scalar_failures=0
check_catalog_line() {
  local expected="$1" label="$2"
  if grep -Fq -- "$expected" <<<"$out"; then
    pass "$label"
  else
    echo "FAIL: $label missing: $expected" >&2
    scalar_failures=$((scalar_failures+1))
  fi
}
check_catalog_line '/folded-strip — folded first folded second' 'folded strip scalar joined with spaces'
check_catalog_line '/folded-clip — clip first clip second' 'folded clip scalar joined with spaces'
check_catalog_line '/literal-clip — literal first literal second' 'literal clip scalar joined with spaces'
check_catalog_line '/literal-strip — strip first strip second' 'literal strip scalar joined with spaces'
check_catalog_line '/inline — inline stays exact' 'plain inline description preserved'
check_catalog_line '/quoted-inline — quoted stays exact' 'quoted inline description preserved'
if grep -Fq -- 'following key must not enter the description' <<<"$out"; then
  echo 'FAIL: following frontmatter key leaked into a block description' >&2
  scalar_failures=$((scalar_failures+1))
else
  pass 'following frontmatter key is excluded from block description'
fi
[[ "$scalar_failures" -eq 0 ]] || exit 1

echo "[6] a match on a non-final line does not report a failure"
# Guards the EPIPE race that broke case [2] on CI: with `set -o pipefail`, a
# matching `printf "%s\n" "$out" | grep -Fq` can still exit non-zero because
# grep -q stops reading and printf dies writing the remaining lines. The output
# here is large enough that the race is lost every time, so this case fails
# deterministically if any assertion helper goes back to a pipe.
big_output="$(seq 1 200000)"
contains '1' "$big_output" || fail "contains lost a match on a non-final line"
pass "match on a non-final line survives pipefail"

echo "export-skill-catalog tests passed"
