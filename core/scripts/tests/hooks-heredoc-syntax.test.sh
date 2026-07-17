#!/usr/bin/env bash
#
# Regression gate for DEV feedback_1513f1f5.
#
# hq-auto-acl-suggest.sh embeds interpreter programs. An earlier form fed them
# into the shell via a heredoc nested inside a `$( … )` command substitution.
# macOS system bash (3.2) mis-parses a heredoc opened inside `$( … )` /
# `<( … )` / backticks as an unterminated quote, so the PostToolUse hook died
# with a syntax error on EVERY Bash/Write/Edit tool call. The fix slurps each
# program into a top-level variable (standalone heredoc) and runs it via
# `node -e "$var"`, which never nests a heredoc inside a substitution.
#
# This gate makes the bug non-recurring on any bash version:
#   1. `bash -n` over every shipped hook (catches genuine unterminated quotes
#      and other syntax errors).
#   2. A structural lint (lint-hook-heredoc-nesting.js) that flags the
#      bash-3.2 nested-heredoc trap directly — bash-version-independent, since
#      CI runs bash 5 and does NOT reproduce the 3.2 phantom error.
#      hq-auto-acl-suggest.sh MUST have zero nesting, and NO hook anywhere
#      under .claude/hooks/ may introduce the pattern (zero violations).
#   3. A runtime smoke of hq-auto-acl-suggest.sh on a sample PostToolUse Bash
#      payload (clean exit, no stderr parser noise).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOKS_DIR="$ROOT/.claude/hooks"
LINT="$ROOT/core/scripts/lint-hook-heredoc-nesting.js"
TARGET_HOOK="$HOOKS_DIR/hq-auto-acl-suggest.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# ── 1. bash -n over every hook ──────────────────────────────────────────────
parsed=0
for hook in "$HOOKS_DIR"/*.sh; do
  [ -f "$hook" ] || continue
  if ! err="$(bash -n "$hook" 2>&1)"; then
    fail "bash -n syntax error in $hook:
$err"
  fi
  parsed=$((parsed + 1))
done
[ "$parsed" -gt 0 ] || fail "no hook scripts found under $HOOKS_DIR"
echo "PASS: bash -n clean across $parsed hook scripts"

# ── 2. structural nested-heredoc lint ───────────────────────────────────────
[ -f "$LINT" ] || fail "missing lint: $LINT"

# 2a. The lint must actually catch the bug it guards against (self-test on a
#     synthetic dquote-wrapped `var="$( … <<PY … )"`, the form that broke the
#     acl hook). A no-op gate is worse than none.
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
BAD="$FIXTURE_DIR/bad.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'out="$('
  printf '%s\n' "python3 - <<'PY'"
  printf '%s\n' 'print("hi")'
  printf '%s\n' 'PY'
  printf '%s\n' ')"'
  printf '%s\n' 'echo "$out"'
} > "$BAD"
if node "$LINT" "$BAD" 2>/dev/null; then
  fail "lint self-test: did NOT catch a heredoc nested in a \"\$( … )\" substitution"
fi
echo "PASS: lint self-test catches the nested-heredoc trap"

# 2b. The acl hook (the file this feedback is about) must have ZERO nesting.
if ! node "$LINT" "$TARGET_HOOK" >/dev/null 2>&1; then
  node "$LINT" "$TARGET_HOOK" || true
  fail "hq-auto-acl-suggest.sh nests a heredoc inside a substitution — the bash-3.2 bug has regressed"
fi
echo "PASS: hq-auto-acl-suggest.sh has no nested heredoc"

# 2c. ZERO violations: NO hook may nest a heredoc inside a substitution.
violations=""
for hook in "$HOOKS_DIR"/*.sh; do
  [ -f "$hook" ] || continue
  if ! node "$LINT" "$hook" >/dev/null 2>&1; then
    violations="$violations $(basename "$hook")"
  fi
done
if [ -n "$violations" ]; then
  node "$LINT" "$HOOKS_DIR"/*.sh || true
  fail "hook(s) nest a heredoc inside a substitution (bash-3.2 trap):$violations
Slurp the heredoc into a top-level variable and run via an argument, e.g.
  prog=\"\"; IFS= read -r -d '' prog <<'PY' || true ... PY ; python3 -c \"\$prog\""
fi
echo "PASS: no hook nests a heredoc inside a substitution (zero violations)"

# ── 3. runtime smoke of the acl hook ────────────────────────────────────────
sample='{"hook_event_name":"PostToolUse","session_id":"gate-smoke","cwd":"'"$ROOT"'","tool_name":"Bash","tool_input":{"command":"echo hello"},"tool_response":{"stdout":"hello"}}'
smoke_err="$(printf '%s' "$sample" | bash "$TARGET_HOOK" 2>&1 >/dev/null)" || \
  fail "hq-auto-acl-suggest.sh exited non-zero on a sample PostToolUse payload"
if printf '%s' "$smoke_err" | grep -qiE 'syntax error|unexpected EOF|unterminated|matching quote'; then
  fail "hq-auto-acl-suggest.sh emitted a parser error at runtime:
$smoke_err"
fi
echo "PASS: hq-auto-acl-suggest.sh runs clean on a sample PostToolUse payload"

echo "ALL CHECKS PASSED"
