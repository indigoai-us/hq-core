#!/usr/bin/env bash
# hq-core: public
# Tests for scope precedence in .claude/hooks/inject-policy-on-trigger.sh
#
# Contract (fleet-agents-full-hq-mode US-003):
#   HQ policy precedence is company > repo > global. The hook collects policy
#   files by walking DIRS in order and `add_match` / the awk `emitted[id]` guard
#   are BOTH first-match-wins on the policy id. Therefore the DIRS order IS the
#   precedence order, and the most-specific scope must be walked FIRST.
#
#   Until 2026-07-19 DIRS was seeded with core/policies first, silently
#   inverting the documented precedence: where a company policy and a core
#   policy shared an `id`, the CORE copy won and the company's copy was dropped
#   — even when the company had deliberately narrowed the trigger or changed
#   the enforcement level.
#
#   This is not a hypothetical. A core policy carrying `on: [SessionStart]` is
#   treated as an always-injected per-session BASELINE — eligible on ANY
#   triggering event, not just SessionStart (see the ss_on branch in finalize()).
#   So a core `when: always` / `on: [SessionStart]` policy competes with a
#   company copy on every single event, and before this fix it won every time.
#
# Each case builds a throwaway HQ_ROOT so the real policy tree is never read.

set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { pass=$((pass+1)); printf '  ok %s\n' "$1"; }

[ -f "$HOOK" ] || fail "hook not found at $HOOK"

# write_policy <file> <id> <when> <on> <enforcement> <rule-text>
write_policy() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
---
id: $2
title: "$2 ($5)"
scope: test
when: $3
on: $4
enforcement: $5
---

## Rule

$6
EOF
}

# run_hook <hq_root> <cwd> <event> <prompt>
run_hook() {
  printf '{"hook_event_name":"%s","cwd":"%s","prompt":"%s"}' "$3" "$2" "$4" \
    | HQ_ROOT="$1" \
      CLAUDE_SESSION_ID="prec-test-$$-${RANDOM}" \
      SESSION_ID="prec-test-$$-${RANDOM}" \
      bash "$HOOK" 2>/dev/null || true
}

# ── Case 1: company copy wins a straight id collision ────────────────────────
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/core/policies" "$ROOT/companies/acme/policies" "$ROOT/.claude/hooks"
cp -R "$HQ_SRC/.claude/hooks/_helpers" "$ROOT/.claude/hooks/_helpers" 2>/dev/null || true

write_policy "$ROOT/core/policies/collide-me.md" \
  "collide-me" "always" "[SessionStart]" "hard" "CORE_COPY_MARKER core rule text."
write_policy "$ROOT/companies/acme/policies/collide-me.md" \
  "collide-me" "always" "[SessionStart, UserPromptSubmit]" "soft" "COMPANY_COPY_MARKER company rule text."

OUT="$(run_hook "$ROOT" "$ROOT/companies/acme" "UserPromptSubmit" "anything at all")"

echo "$OUT" | grep -q "COMPANY_COPY_MARKER" \
  || fail "case1: company copy was NOT emitted. Output was:
$OUT"
ok "company copy wins the id collision"

echo "$OUT" | grep -q "CORE_COPY_MARKER" \
  && fail "case1: core copy WAS emitted — precedence is still inverted. Output was:
$OUT"
ok "core copy emitted zero times"

n="$(printf '%s' "$OUT" | grep -c 'Policy `collide-me`' || true)"
[ "$n" = "1" ] || fail "case1: expected the slug exactly once, got $n"
ok "colliding slug emitted exactly once"

# ── Case 2: a core-only policy still injects (no over-correction) ────────────
write_policy "$ROOT/core/policies/core-only.md" \
  "core-only" "always" "[SessionStart]" "hard" "CORE_ONLY_MARKER survives."
OUT2="$(run_hook "$ROOT" "$ROOT/companies/acme" "UserPromptSubmit" "anything at all")"
echo "$OUT2" | grep -q "CORE_ONLY_MARKER" \
  || fail "case2: a core policy with NO company counterpart was dropped — the fix over-corrected. Output was:
$OUT2"
ok "non-colliding core policy still injects"

# ── Case 3: repo scope also outranks core, and company outranks repo ─────────
ROOT2="$(mktemp -d)"; trap 'rm -rf "$ROOT" "$ROOT2"' EXIT
mkdir -p "$ROOT2/core/policies" "$ROOT2/repos/private/widget/.claude/policies" "$ROOT2/.claude/hooks"
cp -R "$HQ_SRC/.claude/hooks/_helpers" "$ROOT2/.claude/hooks/_helpers" 2>/dev/null || true
write_policy "$ROOT2/core/policies/scoped.md" \
  "scoped" "always" "[SessionStart]" "hard" "CORE_SCOPED_MARKER."
write_policy "$ROOT2/repos/private/widget/.claude/policies/scoped.md" \
  "scoped" "always" "[SessionStart, UserPromptSubmit]" "soft" "REPO_SCOPED_MARKER."

OUT3="$(run_hook "$ROOT2" "$ROOT2/repos/private/widget" "UserPromptSubmit" "anything")"
echo "$OUT3" | grep -q "REPO_SCOPED_MARKER" \
  || fail "case3: repo copy was not emitted. Output was:
$OUT3"
echo "$OUT3" | grep -q "CORE_SCOPED_MARKER" \
  && fail "case3: core copy beat the repo copy. Output was:
$OUT3"
ok "repo scope outranks core"

echo
echo "PASS ($pass assertions)"
