#!/usr/bin/env bash
# Regression coverage for WC-17: skills must not document local scripts that
# were removed with a retired workflow. The checker must reject a broken
# fixture, then pass against the release tree.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LINT="$ROOT/core/scripts/lint-skill-script-refs.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
run_lint_in() { ( cd "$1" && bash "$LINT" "$2" ); }

[[ -f "$LINT" ]] || fail "linter missing: $LINT"

FX="$TMP/scaffold"
mkdir -p "$FX/.claude/skills/demo" "$FX/core/scripts"
printf '# demo\nRun `bash core/scripts/live.sh`.\n' > "$FX/.claude/skills/demo/SKILL.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FX/core/scripts/live.sh"

out="$(run_lint_in "$FX" demo 2>&1)" || fail "Case A: valid local script references should pass; got:\n${out}"
printf '%s\n' "$out" | grep -q '^OK:' || fail "Case A: expected OK output; got:\n${out}"

printf '# demo\nRun `bash core/scripts/retired.sh`.\n' > "$FX/.claude/skills/demo/SKILL.md"
if out="$(run_lint_in "$FX" demo 2>&1)"; then
  fail "Case B: missing documented script should fail, but passed:\n${out}"
fi
printf '%s\n' "$out" | grep -q 'core/scripts/retired.sh' \
  || fail "Case B: failure must name the missing script; got:\n${out}"

out="$( ( cd "$ROOT" && bash "$LINT" learn ) 2>&1 )" \
  || fail "Case C: live learn skill contains a stale local script reference:\n${out}"

if grep -qF 'validate-policy-tags.sh' "$ROOT/.claude/skills/learn/SKILL.md"; then
  fail "Case D: learn skill still names the retired policy-tag validator"
fi

echo "PASS: skill-script-refs (fixture pass/fail + live-tree clean + WC-17 regression)"
