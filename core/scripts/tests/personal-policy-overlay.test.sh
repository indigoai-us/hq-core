#!/usr/bin/env bash
# hq-core: public
# Regression test: policies in personal/policies are surfaced DIRECTLY by the
# inject-policy-on-trigger hook, with NO reindex symlink mirror into
# core/policies. This locks the "personal is the sole read source for the
# personal overlay" behavior — the hook's DIRS must include personal/policies.
#
# The hook resolves its HELPERS (derive-trigger-facts.sh, hook-lib.sh, the
# embedded evaluator) from its OWN location, but resolves the policy scan dirs
# from $HQ_ROOT. So we point HQ_ROOT at a throwaway fixture that contains ONLY a
# personal/policies entry (deliberately no core/policies dir, no symlink) and
# assert the hook still injects it.
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "personal-policy-overlay: skipped (jq missing)"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK not found" >&2; exit 1; }

PASS=0; FAIL=0

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/personal/policies" "$FIX/workspace/orchestrator"
# A reactive personal policy keyed on a unique nonce token so nothing else can
# match it. NOTE: there is intentionally NO $FIX/core/policies directory.
cat > "$FIX/personal/policies/zz-personal-overlay-probe.md" <<'MD'
---
id: zz-personal-overlay-probe
title: Personal overlay probe policy
when: frobnicatexyz
on: [UserPromptSubmit]
enforcement: soft
public: true
---
Personal-overlay policy read directly from personal/policies (no mirror).
MD

emit() { # <session-id> <prompt>
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"%s","prompt":"%s"}' "$1" "$FIX" "$2" \
    | HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" bash "$HOOK" 2>/dev/null || true
}

# 1. The personal policy surfaces when its trigger token appears in the prompt.
OUT="$(emit "ppo-$$-1" "please frobnicatexyz the widget")"
case "$OUT" in
  *zz-personal-overlay-probe*)
    PASS=$((PASS+1)); echo "ok: personal/policies entry injected directly (no symlink mirror)" ;;
  *)
    FAIL=$((FAIL+1)); echo "FAIL[surface]: personal policy did not inject; got: [$OUT]" >&2 ;;
esac

# 2. An unrelated prompt must NOT surface it (no false-positive from the new dir).
OUT2="$(emit "ppo-$$-2" "what time is the standup tomorrow")"
case "$OUT2" in
  *zz-personal-overlay-probe*)
    FAIL=$((FAIL+1)); echo "FAIL[negative]: personal policy surfaced on unrelated prompt; got: [$OUT2]" >&2 ;;
  *)
    PASS=$((PASS+1)); echo "ok: personal policy stays quiet on unrelated prompt" ;;
esac

echo "personal-policy-overlay: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
