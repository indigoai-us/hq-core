#!/usr/bin/env bash
# Regression coverage for DEV-1716 (feedback_b1849da4): core skills instructed
# /run-project + /execute-task, which ship only in the separately-installed
# hq-pack-engineering, so a lean greenfield install hit a documented dead-end.
#
# Guards two things:
#   1. lint-skill-command-refs.sh works on a FRESH-SCAFFOLD fixture — passes when
#      every referenced command resolves, fails (with a pointer) on a dangling
#      reference. This is the generic guard against FUTURE dead-ends.
#   2. The live repo tree is clean AND the specific fix is in place: the
#      execution commands are accounted for in the allowlist and /plan now
#      surfaces the pack install line next to the commands it tells users to run.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LINT="${ROOT}/core/scripts/lint-skill-command-refs.sh"
ALLOW="${ROOT}/core/scripts/skill-command-refs.allow"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$LINT" ]]  || fail "linter missing: $LINT"
[[ -f "$ALLOW" ]] || fail "allowlist missing: $ALLOW"

# ── Fresh-scaffold fixture (a lean hq-core, no engineering pack) ────────────
FX="${TMP}/scaffold"
mkdir -p "${FX}/.claude/skills/handoff" \
         "${FX}/.claude/skills/plan" \
         "${FX}/core/scripts"
# Minimal allowlist: only the pack command the fixture's plan references.
cat > "${FX}/core/scripts/skill-command-refs.allow" <<'ALLOWF'
# fixture allowlist
run-project
ALLOWF
echo "# handoff skill" > "${FX}/.claude/skills/handoff/SKILL.md"
# plan references /handoff (a shipped fixture skill) and /run-project (allowlisted)
cat > "${FX}/.claude/skills/plan/SKILL.md" <<'PLANF'
# plan
To execute, run:
```
  /run-project {name}
```
Then run `/handoff`.
PLANF

run_lint_in() { ( cd "$1" && bash "$LINT" ); }

# Case A: fixture with only resolvable references -> clean (exit 0)
out="$(run_lint_in "$FX" 2>&1)" || fail "Case A: clean fixture should pass; got:\n${out}"
echo "$out" | grep -q '^OK:' || fail "Case A: expected OK line, got:\n${out}"

# Case B: inject a dangling reference -> lint fails and names the command
mkdir -p "${FX}/.claude/skills/broken"
cat > "${FX}/.claude/skills/broken/SKILL.md" <<'BROKENF'
# broken
Now run `/totally-bogus-cmd` to finish.
BROKENF
if out="$(run_lint_in "$FX" 2>&1)"; then
  fail "Case B: dangling reference should fail the lint, but it passed:\n${out}"
fi
echo "$out" | grep -q 'totally-bogus-cmd' \
  || fail "Case B: failure output should name the dangling command; got:\n${out}"
rm -rf "${FX}/.claude/skills/broken"

# Case C: the LIVE repo tree must be clean (no dangling refs ship)
out="$( ( cd "$ROOT" && bash "$LINT" ) 2>&1 )" \
  || fail "Case C: live tree has dangling skill command refs:\n${out}"

# Case D: the reported-bug fix is actually present, not just lint-green.
grep -qE '^run-project$'  "$ALLOW" || fail "Case D: run-project not accounted for in allowlist"
grep -qE '^execute-task$' "$ALLOW" || fail "Case D: execute-task not accounted for in allowlist"
grep -q 'hq install github:indigoai-us/hq-packages#packages/hq-pack-engineering' \
  "${ROOT}/.claude/skills/plan/SKILL.md" \
  || fail "Case D: /plan must surface the engineering-pack install line next to /run-project"

echo "PASS: skill-command-refs (fresh-scaffold pass/fail + live-tree clean + DEV-1716 fix present)"
