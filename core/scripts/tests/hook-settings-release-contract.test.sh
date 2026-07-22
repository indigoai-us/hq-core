#!/usr/bin/env bash
# Release-contract regression guard for DEV-1942 hook settings prevention.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CORE_YAML="$ROOT/core/core.yaml"
SETTINGS="$ROOT/.claude/settings.json"
LOCAL_SETTINGS="$ROOT/.claude/settings.local.json"
UPDATE_SKILL="$ROOT/.claude/skills/update-hq/SKILL.md"
SETUP="$ROOT/core/scripts/setup.sh"
DOC="$ROOT/core/docs/hq/HOOKS-NOT-FIRING.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

echo "[1] the release artifact always contains complete project hook settings"
git ls-files --error-unmatch .claude/settings.json >/dev/null \
  || fail ".claude/settings.json is not tracked in the release artifact"
jq -e '
  [.hooks.SessionStart[]?.hooks[]? | select(.type == "command" and (.command | type == "string") and (.command | length > 0))] | length > 0
' "$SETTINGS" >/dev/null || fail "settings.json has no SessionStart command hook"
jq -e '
  [.hooks.PreToolUse[]?.hooks[]? | select(.type == "command" and (.command | type == "string") and (.command | length > 0))] | length > 0
' "$SETTINGS" >/dev/null || fail "settings.json has no PreToolUse command hook"
jq -e 'has("hooks") | not' "$LOCAL_SETTINGS" >/dev/null \
  || fail "shipped settings.local.json must not shadow project hook registrations"
pass "tracked settings retain SessionStart + PreToolUse hooks without local shadowing"

echo "[2] the staging overlay replaces project settings while retaining local overrides and native personal context"
grep -Fqx '    - .claude' "$CORE_YAML" || fail "staging replacement no longer includes .claude"
grep -Fqx '    - .claude/settings.local.json' "$CORE_YAML" \
  || fail "local settings are no longer preserved across the staging overlay"
grep -Fqx '    - .claude/personal-context.md' "$CORE_YAML" \
  || fail "native personal context is not preserved across the staging overlay"
if grep -Fqx '    - .claude/settings.json' "$CORE_YAML"; then
  fail "project settings must be restored from staging, not preserved as stale local drift"
fi
grep -Fqx '@personal-context.md' "$ROOT/.claude/CLAUDE.md" \
  || fail "locked charter does not natively import the durable personal context"
grep -Fqx '@../personal/CLAUDE.md' "$ROOT/.claude/personal-context.md" \
  || fail "durable personal context does not import existing personal instructions"
grep -Fq 'HQ RUNTIME WARNING:' "$ROOT/.claude/personal-context.md" \
  || fail "durable personal context lacks the app/SDK runtime warning"
for safety_rule in \
  'Never expose, print, paste, commit, or transmit secrets' \
  'Keep company context isolated.' \
  'Treat `core/`, `.claude/`, `.agents/`, `.codex/`, `.obsidian/`, and'; do
  grep -Fq "$safety_rule" "$ROOT/.claude/personal-context.md" \
    || fail "durable personal context is missing critical safety guidance: $safety_rule"
done
pass "overlay restores staged settings and preserves native personal context"

echo "[3] setup and rescue both assert hook health independently of hooks"
grep -Fq 'check-hq-hooks.sh" --root "$REPO_ROOT"' "$SETUP" \
  || fail "setup does not run the hook-health postcheck"
grep -Fq 'check-hq-hooks.sh --root' "$UPDATE_SKILL" \
  || fail "/update-hq does not run the hook-health postcheck"
grep -Fq 'Bash(bash core/scripts/check-hq-hooks.sh:*)' "$UPDATE_SKILL" \
  || fail "/update-hq does not grant its checker command a narrow Bash permission"
grep -Fq 'hq rescue -y' "$UPDATE_SKILL" \
  || fail "/update-hq has no rescue repair command"
grep -Fq -- '--paths .claude' "$UPDATE_SKILL" \
  || fail "/update-hq does not target .claude when hook settings are unhealthy"
pass "setup and rescue detect/recover a dropped project settings file"

echo "[4] user documentation includes the exact runtime remediation"
[ -f "$DOC" ] || fail "hook-failure remediation document is missing"
grep -Fq 'check-hq-hooks.sh --root' "$DOC" || fail "doctor command missing from documentation"
grep -Fq 'settingSources: ["project"]' "$DOC" || fail "SDK settingSources remediation missing from documentation"
grep -Fq 'cwd: hqRoot' "$DOC" || fail "SDK cwd remediation missing from documentation"
grep -Fq 'HOOKS-NOT-FIRING.md' "$ROOT/core/docs/hq/INDEX.md" || fail "hook-failure document is not indexed"
grep -Fq 'HQ runtime enforcement: NOT OBSERVED' "$DOC" \
  || fail "runtime-off warning is not documented"
for event in SessionStart UserPromptSubmit PreToolUse PostToolUse; do
  grep -Fq "\`$event\`" "$DOC" \
    || fail "documentation does not name non-dispatched app/SDK event: $event"
done
pass "documentation is shipped, discoverable, and explains the runtime-off warning"

echo "PASS: hook settings release contract"
