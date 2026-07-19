#!/usr/bin/env bash
# Hermetic release contract for Claude, Codex, Grok, and Cowork surfaces.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
VALIDATOR="$ROOT/core/scripts/validate-agent-runtime-contracts.mjs"
HOOK_LIB="$ROOT/core/scripts/hook-lib.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run() {
  echo "=== $1 ==="
  shift
  "$@"
}

[ -n "${HQ_AGENT_RUNTIME_PARSER_ROOT:-}" ] \
  || fail "HQ_AGENT_RUNTIME_PARSER_ROOT is required; run the validator install-parser command documented in cross-platform-support.md"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run "Cowork + Claude/Codex skill discovery" node "$VALIDATOR"
[ -f "$ROOT/core/packages/hq-pack-cowork/skills/hq-cowork-search/SKILL.md" ] \
  || fail "hq-cowork-search is missing from the shipped Cowork surface"
[ -f "$ROOT/core/packages/hq-pack-cowork/skills/hq-cowork-secrets/SKILL.md" ] \
  || fail "hq-cowork-secrets is missing from the shipped Cowork surface"

run "valid and malformed metadata fixtures" \
  bash "$ROOT/core/scripts/tests/agent-runtime-skill-metadata.test.sh"
run "complete and missing permission fixtures" \
  bash "$ROOT/core/scripts/tests/agent-runtime-permissions.test.sh"
run "Claude executable-bit fallback" \
  bash "$ROOT/core/scripts/tests/hook-gate-exec-bit.test.sh"
run "Codex/Grok advisory and blocking protocols" \
  bash "$ROOT/core/scripts/tests/hook-runtime-diagnostics.test.sh"

. "$HOOK_LIB"
FIX_ROOT="$TMP/hq"
mkdir -p "$FIX_ROOT/workspace"
payload='{"session_id":"runtime-e2e","tool_input":{"command":"token-must-not-leak"}}'
missing="$FIX_ROOT/.claude/hooks/missing.sh"

set +e
hq_launch_shell_path "$FIX_ROOT" "$missing" "$payload" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 127 ] || fail "missing hook should return launch status 127, got $rc"
warning="$(hq_hook_launch_warning_text \
  "$payload" "$FIX_ROOT" "advisory" "hook" "missing" "$missing" "$HQ_HOOK_LAST_CAUSE")"
[ -n "$warning" ] || fail "missing hook must produce visible remediation"
printf '%s' "$warning" | grep -Fq 'chmod u+x "$HQ_ROOT/.claude/hooks/missing.sh"' \
  || fail "missing hook remediation must contain the exact safe chmod command"
if printf '%s' "$warning" | grep -Fq 'token-must-not-leak'; then
  fail "hook payload leaked into remediation"
fi

if grep -Eq '\[ -x "\$script" \] \|\| return 0' \
  "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" \
  "$ROOT/.grok/hooks/hq-grok-hook-adapter.sh"; then
  fail "runtime adapter still silently skips a non-executable hook before recovery"
fi

grep -Fq 'node core/scripts/validate-agent-runtime-contracts.mjs' \
  "$ROOT/core/knowledge/public/hq-core/cross-platform-support.md" \
  || fail "cross-platform docs must include the local validation command"

echo "ALL PASS: agent-runtime-contracts-e2e (Claude, Codex, Grok, Cowork)"
