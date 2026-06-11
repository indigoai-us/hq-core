#!/usr/bin/env bash
# Regression coverage for DEV-1727 (feedback_f4f48522): the /setup wizard
# `which vercel`-ed and offered `npm install -g vercel` during base setup, even
# though HQ's own features never call the Vercel CLI (/deploy targets hq-deploy).
# That made an irrelevant third-party tool an install dependency for everyone.
#
# Guards two things:
#   1. lint-install-deps.sh works on a FRESH fixture — passes when the install
#      surface only NAMES a denied tool (prose), fails when it actually installs
#      or dependency-checks it. This is the generic guard against FUTURE creep.
#   2. The live repo tree is clean AND the specific fix is in place: the setup
#      wizard no longer installs/checks vercel, and vercel is on the denylist.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LINT="${ROOT}/core/scripts/lint-install-deps.sh"
DENY="${ROOT}/core/scripts/install-deps.deny"
SETUP_SKILL="${ROOT}/.claude/skills/setup/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$LINT" ]] || fail "linter missing: $LINT"
[[ -f "$DENY" ]] || fail "denylist missing: $DENY"

# ── Fresh fixture (a lean install surface) ──────────────────────────────────
FX="${TMP}/scaffold"
mkdir -p "${FX}/core/scripts" "${FX}/.claude/skills/setup"
cat > "${FX}/core/scripts/install-deps.deny" <<'DENYF'
# fixture denylist
vercel
DENYF
# A clean setup wizard that merely NAMES vercel while telling you NOT to install
# it — this must PASS (prose mention is fine; only the install/check is banned).
cat > "${FX}/.claude/skills/setup/SKILL.md" <<'SETUPF'
# setup
## Phase 0b: Auth checks
- `gh auth status` — offer `gh auth login` if unauthenticated

Do not check for or install third-party deploy CLIs (e.g. the Vercel CLI) here;
HQ never shells out to them. See core/policies/hq-vercel.md for usage guidance.
SETUPF

run_lint_in() { ( cd "$1" && bash "$LINT" ); }

# Case A: clean surface that only names the tool -> passes (exit 0)
out="$(run_lint_in "$FX" 2>&1)" || fail "Case A: clean fixture should pass; got:
${out}"
echo "$out" | grep -q '^OK:' || fail "Case A: expected OK line, got:
${out}"

# Case B: re-introduce the dependency (which + npm install -g) -> lint fails
cat >> "${FX}/.claude/skills/setup/SKILL.md" <<'BADF'

**Vercel CLI:**
```bash
which vercel
```
If missing, offer to install (`npm install -g vercel`).
BADF
if out="$(run_lint_in "$FX" 2>&1)"; then
  fail "Case B: re-introduced vercel install/check should fail the lint, but it passed:
${out}"
fi
echo "$out" | grep -q 'vercel' \
  || fail "Case B: failure output should name the denied tool; got:
${out}"

# Case B2: an auth-gate invocation alone also trips the lint
FX2="${TMP}/scaffold2"
mkdir -p "${FX2}/core/scripts" "${FX2}/.claude/skills/setup"
cp "${FX}/core/scripts/install-deps.deny" "${FX2}/core/scripts/install-deps.deny"
printf '# setup\nRun `vercel whoami` and offer `vercel login`.\n' \
  > "${FX2}/.claude/skills/setup/SKILL.md"
if out="$(run_lint_in "$FX2" 2>&1)"; then
  fail "Case B2: 'vercel whoami' auth-gate should fail the lint, but it passed:
${out}"
fi

# Case C: the LIVE repo tree must be clean
out="$( ( cd "$ROOT" && bash "$LINT" ) 2>&1 )" \
  || fail "Case C: live install surface installs/checks a denied tool:
${out}"

# Case D: the reported-bug fix is actually present, not just lint-green.
grep -qE '^vercel$' "$DENY" || fail "Case D: vercel not on install-deps.deny"
if [[ -f "$SETUP_SKILL" ]]; then
  grep -qiE '\bwhich[[:space:]]+vercel\b|install[[:space:]]+-g[[:space:]]+vercel|\bvercel[[:space:]]+(whoami|login)\b' \
    "$SETUP_SKILL" \
    && fail "Case D: setup wizard still installs/checks vercel"
fi

echo "PASS: install-deps (prose-ok + install/check fails + live-tree clean + DEV-1727 fix present)"
