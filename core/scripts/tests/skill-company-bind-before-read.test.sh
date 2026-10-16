#!/usr/bin/env bash
# skill-company-bind-before-read.test.sh — a skill that anchors a company must
# bind the session to it before its first read under companies/{co}/
# (feedback_74bfcdbc).
#
# /brainstorm anchored {co} in Step 0 and then loaded company policies and ran
# research reads, but its only bind ran above Step 0, before {co} was known. The
# scope guard denied the first company read with "Session has no company_slug
# bound". /deep-plan, /prd, /strategize, /investigate and /project-summary had
# the same order. The linter must catch each shape in fixtures, accept the
# bound forms, and then pass on every shipped skill.
#
# Explicitly wired into .github/workflows/pr-checks.yml.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LINT="$ROOT/core/scripts/lint-skill-company-bind.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f "$LINT" ]] || fail "linter missing: $LINT"

FX="$TMP/skills"
write_skill() {
  rm -rf "$FX"
  mkdir -p "$FX/$1"
  cat > "$FX/$1/SKILL.md"
}

expect_fail() {
  local label="$1" want="$2" out
  if out="$(bash "$LINT" "$FX" 2>&1)"; then
    fail "$label: lint passed but should have failed"
  fi
  grep -qF -- "$want" <<<"$out" || fail "$label: expected '$want' in output, got:
$out"
}

expect_pass() {
  local label="$1" out
  out="$(bash "$LINT" "$FX" 2>&1)" || fail "$label: lint failed but should pass:
$out"
}

# --- shapes that must fail ---------------------------------------------------
write_skill demo <<'MD'
---
name: demo
description: Fixture.
---
## Step 0
1. **Set `{co}`** = matched slug
2. **Announce:** "Anchored on **{co}**"
3. Read `companies/{co}/board.json`
MD
expect_fail "anchor then company read, no bind" 'SKILL.md:8: reads a company path before the session is bound (company anchored at line 6)'
echo "ok 1 anchor then read"

write_skill demo <<'MD'
## Trusted bind (do this first)
```bash
bash core/scripts/work-mesh-live-bind-trusted.sh \
  --company "{co}" --project "{project}"
```
## Step 0
1. **Set `{co}`** = matched slug
2. **Announce:** "Anchored on **{co}**"
3. **Load policies** — run read-policy-frontmatter on each policy file
MD
expect_fail "bind above the anchor does not count" 'reads a company path before the session is bound'
echo "ok 2 bind before anchor"

write_skill demo <<'MD'
2. **Announce:** "Anchored on **{co}**"
3. Load policies with read-policy-frontmatter
4. bash core/scripts/hq-session.sh set company_slug "{co}"
MD
expect_fail "policy load before bind" 'reads a company path before the session is bound'
echo "ok 3 policy load before bind"

write_skill demo <<'MD'
1. Set `{co}` = matched slug, strip from input
2. Load policies: `companies/{co}/policies/`
MD
expect_fail "plain Set anchor" 'reads a company path before the session is bound'
echo "ok 4 plain Set anchor"

# --- bound forms that must pass ----------------------------------------------
write_skill demo <<'MD'
---
name: demo
description: Frontmatter mentions companies/{co}/ and Set `{co}` but is skipped.
---
1. **Set `{co}`** = matched slug
2. **Announce:** "Anchored on **{co}**"
3. **Bind the session** — run `bash core/scripts/work-mesh-live-bind-trusted.sh --company "{co}"`
4. Read `companies/{co}/board.json` and run read-policy-frontmatter
MD
expect_pass "trusted bind after anchor"
echo "ok 5 trusted bind after anchor"

write_skill demo <<'MD'
1. Set `{co}` = matched slug
```bash
bash core/scripts/hq-session.sh set company_slug "{co}"
```
2. Load policies: `companies/{co}/policies/`
MD
expect_pass "hq-session set company_slug after anchor"
echo "ok 6 hq-session set"

write_skill demo <<'MD'
1. Set `{co}` = matched slug
2. `bash core/scripts/hq-session.sh add company "{co}"`
3. Read `companies/{co}/board.json`
MD
expect_pass "hq-session add company after anchor"
echo "ok 7 hq-session add company"

write_skill demo <<'MD'
1. Set `{co}` = matched slug
2. Run `hq core hq-session set company_slug "{co}"`
3. Read `companies/{co}/board.json`
MD
expect_pass "hq core hq-session set company_slug after anchor"
echo "ok 8 hq core hq-session set"

write_skill demo <<'MD'
Resolve the company from `bash core/scripts/hq-session.sh get company_slug`.
Read `companies/{co}/board.json`.
MD
expect_pass "no anchor, already-bound company"
echo "ok 9 no anchor is not checked"

write_skill demo <<'MD'
1. Set `{co}` = matched slug
2. Pass `{co}` to the runner; no company reads here.
MD
expect_pass "anchor without company reads"
echo "ok 10 anchor without reads"

# --- every shipped skill -----------------------------------------------------
out="$(cd "$ROOT" && bash "$LINT" .claude/skills 2>&1)" \
  || fail "shipped skills read company paths before binding the session:
$out"
echo "ok 11 shipped skills bind before company reads"

echo "skill-company-bind-before-read.test.sh: 11/11 passed"
