#!/usr/bin/env bash
# Regression coverage for DEV-1716 (feedback_b1849da4): core skills instructed
# /run-project + /execute-task, which ship only in the separately-installed
# hq-pack-engineering, so a lean greenfield install hit a documented dead-end.
#
# Guards two things:
#   1. lint-skill-command-refs.sh works on a FRESH-SCAFFOLD fixture — passes when
#      every release-guidance reference resolves, fails (with a pointer) on a
#      dangling reference. This is the generic guard against FUTURE dead-ends.
#   2. The live repo tree is clean AND the specific fixes are in place: the
#      execution commands are accounted for in the allowlist and /plan now
#      surfaces the pack install line next to the commands it tells users to run;
#      invitation guidance routes through the shipped new-hire workflow.

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
         "${FX}/.claude/skills/new-hire" \
         "${FX}/.claude/skills/signals" \
         "${FX}/.claude/hooks" \
         "${FX}/core/policies" \
         "${FX}/core/scripts"
# Minimal allowlist: only the pack command the fixture's plan references.
cat > "${FX}/core/scripts/skill-command-refs.allow" <<'ALLOWF'
# fixture allowlist
run-project
ALLOWF
echo "# handoff skill" > "${FX}/.claude/skills/handoff/SKILL.md"
echo "# new-hire skill" > "${FX}/.claude/skills/new-hire/SKILL.md"
echo "# signals skill" > "${FX}/.claude/skills/signals/SKILL.md"
# plan references /handoff (a shipped fixture skill) and /run-project (allowlisted)
cat > "${FX}/.claude/skills/plan/SKILL.md" <<'PLANF'
# plan
To execute, run:
```
  /run-project {name}
```
Then run `/handoff`.
PLANF
# Release policies and hook-injected text are linted too. The Slack invite is
# deliberately a native Slack command, not an HQ command alias.
cat > "${FX}/core/policies/routes.md" <<'ROUTESF'
# routes
Invite a teammate with ⚠ `/new-hire [EMAIL] acme`.
Use `/fixture:signals` for the company view.
ROUTESF
cat > "${FX}/core/policies/hq-slack.md" <<'SLACKF'
# Slack
Invite the bot with `/invite @bot-name` from Slack.
SLACKF
cat > "${FX}/.claude/hooks/router.sh" <<'HOOKF'
cat <<'JSONOUT'
{"hookSpecificOutput":{"additionalContext":"Route invitations by running /new-hire."}}
JSONOUT
HOOKF

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

# Case C: namespaced commands must resolve their target rather than bypassing
# the lint, and a top-level hq invite alias is never valid guidance.
cat > "${FX}/core/policies/broken.md" <<'NAMESPACEF'
# broken namespace
Run `/personal:missing`.
NAMESPACEF
if out="$(run_lint_in "$FX" 2>&1)"; then
  fail "Case C: dangling namespaced target should fail the lint, but it passed:\n${out}"
fi
echo "$out" | grep -q 'personal:missing' \
  || fail "Case C: failure output should name the namespaced target; got:\n${out}"
rm -f "${FX}/core/policies/broken.md"

cat > "${FX}/core/policies/broken.md" <<'HQINVITEF'
# broken CLI guidance
Run `hq invite [EMAIL]`.
HQINVITEF
if out="$(run_lint_in "$FX" 2>&1)"; then
  fail "Case C: top-level hq invite should fail the lint, but it passed:\n${out}"
fi
echo "$out" | grep -q 'hq invite' \
  || fail "Case C: failure output should name hq invite; got:\n${out}"
rm -f "${FX}/core/policies/broken.md"

cat > "${FX}/core/policies/broken.md" <<'SLACKINVITEF'
# not Slack
Invite a person with `/invite @person`.
SLACKINVITEF
if out="$(run_lint_in "$FX" 2>&1)"; then
  fail "Case C: /invite outside Slack should fail the lint, but it passed:\n${out}"
fi
echo "$out" | grep -q '/invite' \
  || fail "Case C: failure output should name /invite; got:\n${out}"
rm -f "${FX}/core/policies/broken.md"

cat > "${FX}/.claude/hooks/broken.sh" <<'HOOKF'
cat <<'JSONOUT'
{"hookSpecificOutput":{"additionalContext":"Route by running /missing-hook-command."}}
JSONOUT
HOOKF
if out="$(run_lint_in "$FX" 2>&1)"; then
  fail "Case C: dangling hook route should fail the lint, but it passed:\n${out}"
fi
echo "$out" | grep -q 'missing-hook-command' \
  || fail "Case C: failure output should name the hook command; got:\n${out}"
rm -f "${FX}/.claude/hooks/broken.sh"

# Case D: the LIVE repo tree must be clean (no dangling refs ship)
out="$( ( cd "$ROOT" && bash "$LINT" ) 2>&1 )" \
  || fail "Case D: live tree has dangling release-guidance command refs:\n${out}"

# Case E: the reported-bug fixes are actually present, not just lint-green.
grep -qE '^run-project$'  "$ALLOW" || fail "Case E: run-project not accounted for in allowlist"
grep -qE '^execute-task$' "$ALLOW" || fail "Case E: execute-task not accounted for in allowlist"
grep -q 'hq install github:indigoai-us/hq-packages#packages/hq-pack-engineering' \
  "${ROOT}/.claude/skills/plan/SKILL.md" \
  || fail "Case E: /plan must surface the engineering-pack install line next to /run-project"
grep -qF '`/new-hire {email} {company}`' "${ROOT}/core/policies/natural-language-mode.md" \
  || fail "Case E: invitation route must use /new-hire with email and company"
if grep -qF '/personal:invite' "${ROOT}/core/policies/natural-language-mode.md"; then
  fail "Case E: stale /personal:invite route remains in natural-language policy"
fi
grep -q 'newcompany, new-hire, designate-team' "${ROOT}/.claude/hooks/natural-language-router.sh" \
  || fail "Case E: invitation risk gate must name new-hire"
if grep -q 'newcompany, invite, designate-team' "${ROOT}/.claude/hooks/natural-language-router.sh"; then
  fail "Case E: stale invite risk-gate token remains in hook"
fi
grep -qF 'hq groups|secrets|files|members invite' "${ROOT}/.claude/skills/newcompany/SKILL.md" \
  || fail "Case E: newcompany summary must use hq members invite"
if grep -qF 'hq groups|secrets|files|invite' "${ROOT}/.claude/skills/newcompany/SKILL.md"; then
  fail "Case E: stale hq ...|invite summary remains in newcompany"
fi

echo "PASS: skill-command-refs (release guidance pass/fail + live-tree clean + invite guidance fix present)"
