#!/usr/bin/env bash
# Feedback 2313: hq-heal CLI restore must use pnpm + minimumReleaseAge, never
# npm @latest (blocked by hq-pnpm-min-release-age-supply-chain).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HEAL="$ROOT/.claude/skills/hq-heal/SKILL.md"
ENSURE="$ROOT/core/hooks/UserPromptSubmit/30-ensure-hq-cli.sh"
CHECKUP="$ROOT/.claude/skills/hq-checkup/hq-checkup.sh"
RESTORE='pnpm add -g @indigoai-us/hq-cli@latest --config.minimumReleaseAge=1440'
NPM_LATEST='npm install -g @indigoai-us/hq-cli@latest'

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$HEAL" ] || fail "missing $HEAL"
[ -f "$ENSURE" ] || fail "missing $ENSURE"
[ -f "$CHECKUP" ] || fail "missing $CHECKUP"

grep -F "$RESTORE" "$HEAL" >/dev/null \
  || fail "hq-heal SKILL.md must document the pnpm age-gated restore"
grep -F "Never restore the \`hq\` CLI with \`$NPM_LATEST\`" "$HEAL" >/dev/null \
  || fail "hq-heal SKILL.md must forbid npm @latest restore"

# The only allowed mentions of npm @latest in heal are the forbid / blocked-command cases.
if grep -F "$NPM_LATEST" "$HEAL" | grep -v 'Do **not** retry npm' | grep -v 'Never restore' | grep -v 'blocked `' >/dev/null; then
  fail "hq-heal SKILL.md still recommends npm @latest as a restore"
fi

grep -F "$RESTORE" "$ENSURE" >/dev/null \
  || fail "ensure-hq-cli must document the pnpm age-gated restore"
grep -E 'pnpm add -g (\$\{HQ_CLI_PKG\}|@indigoai-us/hq-cli)@latest --config.minimumReleaseAge=1440' "$CHECKUP" >/dev/null \
  || fail "hq-checkup must document the pnpm age-gated restore"

# feedback e49ce279: a stale pnpm copy behind a ~/.local/bin wrapper shadowed the
# auto-updated npm copy; heal must diagnose the two installs and update the one
# `command -v hq` resolves to.
grep -F 'Stale shadowing CLI install' "$HEAL" >/dev/null \
  || fail "hq-heal SKILL.md must diagnose a stale shadowing hq install"
grep -F 'update the install that `command -v hq` resolves to' "$HEAL" >/dev/null \
  || fail "hq-heal SKILL.md must target the install command -v hq resolves to"

echo "PASS: hq-heal CLI restore uses pnpm + minimumReleaseAge=1440"
