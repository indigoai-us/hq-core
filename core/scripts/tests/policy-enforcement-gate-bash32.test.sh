#!/usr/bin/env bash
# Regression test: the policy enforcement gate's UserPromptSubmit path must
# parse and run under stock macOS /bin/bash (3.2). A `case` pattern inside a
# `$(...)` substitution made 3.2 stop at the pattern's ")" and fail with
# "syntax error near unexpected token `newline'", so every prompt on a Mac
# that ran the gate under /bin/bash lost its requirement declaration.
#
# BASH_BIN overrides the interpreter (default /bin/bash).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="${HQ_TEST_POLICY_GATE_HOOK:-$ROOT/.claude/hooks/policy-enforcement-gate.sh}"
BASH_BIN="${BASH_BIN:-/bin/bash}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

[ -x "$BASH_BIN" ] || fail "interpreter not found: $BASH_BIN"
echo "interpreter: $BASH_BIN ($("$BASH_BIN" -c 'printf %s "$BASH_VERSION"'))"

mkdir -p "$FIX/.claude/hooks" "$FIX/.claude/skills/security-review" \
  "$FIX/workspace/orchestrator/policy-enforcement" "$FIX/core/scripts/lib"
cp "$HOOK" "$FIX/.claude/hooks/policy-enforcement-gate.sh"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIX/core/scripts/hook-lib.sh"
cp "$ROOT/core/scripts/lib/session-id.sh" "$FIX/core/scripts/lib/session-id.sh"
printf '# Security Review\n' > "$FIX/.claude/skills/security-review/SKILL.md"

# bash 3.2 parses a command substitution only when it runs, so this check
# alone does not catch the bug; the UserPromptSubmit runs below do.
"$BASH_BIN" -n "$FIX/.claude/hooks/policy-enforcement-gate.sh" 2> "$TMP/syntax.err" \
  || fail "gate does not parse under $BASH_BIN: $(cat "$TMP/syntax.err")"
pass "gate parses under $BASH_BIN"

run_prompt() {
  local sid="$1" prompt="$2" payload
  payload="$(jq -nc --arg sid "$sid" --arg prompt "$prompt" '{session_id:$sid,prompt:$prompt}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$FIX" "$BASH_BIN" "$FIX/.claude/hooks/policy-enforcement-gate.sh" UserPromptSubmit >/dev/null 2> "$TMP/run.err" \
    || fail "UserPromptSubmit failed under $BASH_BIN for $sid: $(cat "$TMP/run.err")"
  [ ! -s "$TMP/run.err" ] || fail "UserPromptSubmit wrote to stderr under $BASH_BIN for $sid: $(cat "$TMP/run.err")"
}

STATE_DIR="$FIX/workspace/orchestrator/policy-enforcement"

run_prompt "bash32-plain" "hello there"
jq -e '.requiredSkills == []' "$STATE_DIR/bash32-plain.json" >/dev/null \
  || fail "plain prompt declared skills: $(cat "$STATE_DIR/bash32-plain.json")"
pass "plain prompt declares no skills under $BASH_BIN"

run_prompt "bash32-named" "Please use the security-review skill on this change."
jq -e '.requiredSkills == ["security-review"]' "$STATE_DIR/bash32-named.json" >/dev/null \
  || fail "named skill not declared: $(cat "$STATE_DIR/bash32-named.json")"
pass "prompt-named installed skill is declared under $BASH_BIN"

run_prompt "bash32-unknown" "Please use HQ skill to rename this."
jq -e '.requiredSkills == []' "$STATE_DIR/bash32-unknown.json" >/dev/null \
  || fail "uninstalled skill name was declared: $(cat "$STATE_DIR/bash32-unknown.json")"
pass "prompt-named uninstalled skill is not declared under $BASH_BIN"

echo "policy-enforcement-gate-bash32.test.sh: all passed"
