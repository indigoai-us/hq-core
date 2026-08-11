#!/usr/bin/env bash
# Regression coverage for the reported /setup onboarding friction: the wizard
# paused mid-flow to ask how to handle missing CLI tools (hq-cli, qmd, gh) with
# an "install all / install some / skip all" picker. The fix makes /setup install
# missing dependencies directly and non-blocking. This test pins the invariant so
# the prompt-the-user behavior cannot silently return, and guards the follow-on
# correctness the fix depends on (platform-aware installs, bootstrap-dep escape
# hatch, and a place to report failures).
#
# It asserts against the LIVE skill text (.claude/skills/setup/SKILL.md) — the
# skill is prose an agent reads and executes, so the contract lives in the words.

set -euo pipefail

# NOTE: use `grep -q PAT <<<"$var"`, never `echo "$var" | grep -q PAT` — with
# pipefail a SIGPIPE on the writer can turn a passing assertion into a failure.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="${ROOT}/.claude/skills/setup/SKILL.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$SKILL" ]] || fail "setup skill missing: $SKILL"
body="$(cat "$SKILL")"

# ── 1. The direct-install invariant is present ──────────────────────────────
grep -qF 'Install missing dependencies and CLI tools directly — never ask' <<<"$body" \
  || fail "1: the 'install directly, never ask' invariant is missing from the setup skill"

# ── 2. The old choose-your-install prompt behavior is GONE ──────────────────
# These are the exact phrasings the regression produced. If any returns, the
# wizard is asking the user how to handle tools again.
while IFS= read -r bad; do
  [[ -z "$bad" ]] && continue
  if grep -qF "$bad" <<<"$body"; then
    fail "2: stale ask-the-user phrasing returned to the setup skill: '$bad'"
  fi
done <<'BADPHRASES'
For P2 items: offer with context
Would you like me to install it now?
explain benefit and offer
BADPHRASES

# An "install all / some / none" style picker must not be reintroduced. The skill
# names that anti-pattern to forbid it; it must never appear as an instruction to
# actually present one. Assert the forbidding language frames every mention.
grep -qE 'never (surface|present) an .*install(-| )all' <<<"$body" \
  || fail "2: the setup skill must explicitly forbid the install-all/some/none picker"

# ── 3. The interactive-auth exception is spelled out ────────────────────────
# Installs are direct, but a browser auth (gh auth login) legitimately prompts —
# that carve-out must stay so the rule isn't read as "never prompt for anything".
grep -qF 'gh auth login' <<<"$body" \
  || fail "3: the interactive-auth exception (gh auth login) is missing"
grep -qiE 'interactive auth' <<<"$body" \
  || fail "3: the setup skill must name the interactive-auth exception to the no-prompt rule"

# ── 4. Bootstrap-dependency escape hatch exists (Node / a bare package mgr) ──
# The direct-install rule can't apply to Node itself (there's no npm to install
# it with). The skill must carve that out, or it contradicts its own P0 triage.
grep -qiE 'bootstrap dependenc' <<<"$body" \
  || fail "4: the setup skill must exempt bootstrap dependencies (e.g. Node) from the direct-install rule"

# ── 5. Platform-aware installs, not Homebrew-only ───────────────────────────
# gh install must degrade across brew / apt / winget so a non-macOS install
# isn't silently left without gh.
for mgr in 'brew install gh' 'apt-get install -y gh' 'winget install'; do
  grep -qF "$mgr" <<<"$body" \
    || fail "5: gh install path must cover '$mgr' (platform-aware, not Homebrew-only)"
done

# ── 6. macOS SQLite is actually installed for qmd, not just mentioned ────────
grep -qF 'brew install sqlite' <<<"$body" \
  || fail "6: qmd setup must install Homebrew SQLite on macOS (not only mention it in a comment)"

# ── 7. Failures have somewhere to surface — the Phase 3 summary section ──────
grep -qF 'Still needs attention:' <<<"$body" \
  || fail "7: the Phase 3 summary template must include a 'Still needs attention:' section for failed installs"

echo "PASS: setup-skill-direct-install (direct-install invariant held; picker gone; auth/bootstrap carve-outs, platform-aware installs, and failure reporting present)"
