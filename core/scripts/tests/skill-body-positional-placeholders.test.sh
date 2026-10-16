#!/usr/bin/env bash
# skill-body-positional-placeholders.test.sh — shipped SKILL.md bodies must not
# contain text that Claude Code replaces with the skill's arguments
# (feedback_46af098f).
#
# Claude Code substitutes $ARGUMENTS, $ARGUMENTS[N] and $N (0-based, multi-digit)
# anywhere in a SKILL.md body, fenced code included, whenever argument N exists.
# The /deploy skill's `local stage="$1"` therefore became the dist folder,
# `awk '{print $1}'` printed an argument, and "$10 a month" changed with the
# argument count. The linter must catch each shape in fixtures, accept the safe
# forms, and then pass on every shipped skill.
#
# Explicitly wired into .github/workflows/pr-checks.yml.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LINT="$ROOT/core/scripts/lint-skill-positional-args.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f "$LINT" ]] || fail "linter missing: $LINT"

# write_skill <name> — SKILL.md body from stdin, under a fresh fixture dir.
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
```bash
deploy_request() {
  local stage="$1"
  shift
}
```
MD
expect_fail "fenced \$1 in a shell function" 'bare $1'
echo "ok 1 fenced shell positional"

write_skill demo <<'MD'
```bash
TARBALL_SHA256=$(shasum -a 256 "$TARBALL_PATH" | awk '{print $1}')
```
MD
expect_fail "awk field \$1" 'bare $1'
echo "ok 2 awk field"

write_skill demo <<'MD'
> Adding a database costs $10 a month.
MD
expect_fail "prose price \$10" 'bare $10'
echo "ok 3 prose dollar amount"

write_skill demo <<'MD'
```sh
echo "$0"
```
MD
expect_fail "\$0 is the first argument" 'bare $0'
echo "ok 4 dollar-zero"

write_skill demo <<'MD'
```bash
x=\\$1
```
MD
expect_fail "double backslash does not escape" 'bare $1'
echo "ok 5 double backslash"

write_skill demo <<'MD'
```bash
run "$ARGUMENTS"
pick "$ARGUMENTS[0]"
```
MD
expect_fail "fenced \$ARGUMENTS outside the allowlist" '$ARGUMENTS in a fenced block'
echo "ok 6 fenced ARGUMENTS"

write_skill hq-sync <<'MD'
No fenced use of the arguments here; prose $ARGUMENTS only.
MD
expect_fail "stale allowlist entry" 'listed in ALLOW_FENCED_ARGUMENTS'
echo "ok 7 stale allowlist entry"

# --- safe forms that must pass -----------------------------------------------
write_skill demo <<'MD'
---
name: demo
description: Frontmatter is not substituted, so $1 here is fine.
---
**Input:** $ARGUMENTS

Costs \$10 a month and \$1.32 per GB.

```bash
deploy_request() {
  local stage="${1}"
  shift
  run --stage "$stage" "$@"
}
sum=$(shasum -a 256 "$f" | cut -d' ' -f1)
role=$(awk -v me="$me" '$(1)==me {print $(2)}' members.txt)
echo "$#" "$?" "$$" "${2:-x}" "$HOME"
```
MD
expect_pass "safe forms"
echo "ok 8 safe forms pass"

write_skill convert-codex <<'MD'
```bash
bash core/scripts/convert-codex.sh $ARGUMENTS
```
MD
expect_pass "allowlisted fenced ARGUMENTS"
echo "ok 9 allowlisted fenced ARGUMENTS"

# --- every shipped skill -----------------------------------------------------
out="$(cd "$ROOT" && bash "$LINT" .claude/skills 2>&1)" \
  || fail "shipped skills contain argument placeholders in their bodies:
$out"
echo "ok 10 shipped skills are clean"

echo "skill-body-positional-placeholders.test.sh: 10/10 passed"
