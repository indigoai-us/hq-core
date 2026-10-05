#!/usr/bin/env bash
# Guards the "check hq integrations first" routing surface:
#   1. hq-integrations SKILL.md description carries concrete external-app
#      triggers and the "FIRST / fall back" directive agents match on.
#   2. The release charter (.claude/CLAUDE.md, which AGENTS.md symlinks)
#      restates the same rule in prose so Codex and fleet agents inherit it.
# Regression gate for the fix shipped alongside this test.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SKILL="$ROOT/.claude/skills/hq-integrations/SKILL.md"
CHARTER="$ROOT/.claude/CLAUDE.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[[ -f "$SKILL" ]]   || fail "missing $SKILL"
[[ -f "$CHARTER" ]] || fail "missing $CHARTER"

desc_line="$(awk '/^description:/{print; exit}' "$SKILL")"
[[ -n "$desc_line" ]] || fail "SKILL.md has no description field"

# Concrete connected-app names (sample of the big ones users name).
for needle in Linear Notion Jira GitHub Slack Sentry; do
  grep -F -- "$needle" <<<"$desc_line" >/dev/null \
    || fail "SKILL.md description missing concrete app name: $needle"
done
pass "SKILL.md description names concrete external apps"

# The directive that routes external-app requests through HQ first.
grep -F -- "hq integrations list" <<<"$desc_line" >/dev/null \
  || fail "SKILL.md description missing 'hq integrations list' directive"
grep -E -i -- "BEFORE|fall back" <<<"$desc_line" >/dev/null \
  || fail "SKILL.md description missing BEFORE/fall-back directive"
pass "SKILL.md description carries the HQ-first routing directive"

# Charter restates the same rule in prose (feeds Codex via AGENTS.md symlink).
# Normalize whitespace so a wrapped bullet still matches.
charter_flat="$(tr '\n' ' ' <"$CHARTER" | tr -s ' ')"
grep -F -- "hq integrations list" <<<"$charter_flat" >/dev/null \
  || fail "charter missing 'hq integrations list' routing rule"
grep -E -- "FIRST" <<<"$charter_flat" >/dev/null \
  || fail "charter missing FIRST routing directive"
pass "charter restates the HQ-integrations-first routing rule"

echo "PASS: $0"
