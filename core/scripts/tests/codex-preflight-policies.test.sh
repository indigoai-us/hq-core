#!/usr/bin/env bash
# codex-preflight-policies.test.sh — US-002 acceptance battery for the
# cross-runtime reach of core/policies/hq-prefer-native-capabilities.md.
#
# Codex has no push injection. There are two paths and #666 moved this policy
# from the first to the second:
#   - `core/scripts/codex-preflight.sh policies` re-runs the trigger hook with a
#     synthetic SessionStart payload. Only on:[SessionStart] policies surface
#     here, so a reactive-only policy must NOT appear.
#   - `.codex/hooks/hq-codex-hook-adapter.sh` forwards UserPromptSubmit to the
#     same hook, which is how a reactive policy reaches Codex.
# Cross-runtime reach (the point of US-002) is therefore asserted on the
# reactive path. Asserts:
#   1. preflight does NOT emit hq-prefer-native-capabilities (reactive-only),
#      while two distinct Codex sessions BOTH receive it on a matching prompt.
#   2. .grok/rules/hq-prefer-native-capabilities.md exists, retains /deploy for
#      URL artifacts, and permits explicitly requested local Slack attachments
#      through the native audited upload helper.
#   3. codex-skill-bridge.sh status still runs cleanly (no regression).
#
# Dedupe is session-scoped: the preflight stamps a per-session session_id
# (codex-preflight-$PPID by default, --session to override) so a second
# SESSION still gets the policies, and the shared default.txt ledger is
# never written (it is runtime state, gitignored — not shipped).
#
# Explicitly wired into .github/workflows/pr-checks.yml — tests here are NOT
# auto-discovered (indigo-hq-core-staging-pr-mechanics rule 3).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SLUG="hq-prefer-native-capabilities"
LEDGER_DIR="$ROOT/workspace/orchestrator/policy-trigger-state"
DEFAULT_LEDGER="$LEDGER_DIR/default.txt"
RUN="cpp-$$-$RANDOM"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

# Remove only the ledgers this run creates; note whether default.txt predates us.
# The adapter writes <id>.txt, <id>.turn.txt and <id>.nl-router-fired, and the
# UserPromptSubmit fan-out also drops per-session markers under .claude/state.
trap 'rm -f "$LEDGER_DIR/$RUN-a.txt" "$LEDGER_DIR/$RUN-b.txt" "$LEDGER_DIR"/*"$RUN"* \
  "$ROOT/.claude/state"/*"$RUN"* 2>/dev/null || true' EXIT

ADAPTER="$ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
# codex_prompt <session-suffix> -> adapter stdout for a policy-matching prompt.
#
# The adapter dispatches EVERY UserPromptSubmit hook in settings.json, not just
# the policy injector. auto-session-project is one of them, and it would mint a
# real project folder from the test prompt — so disable it here. This battery is
# about policy reach; unrelated hooks must not write into the checkout.
codex_prompt() {
  printf '{"hook_event_name":"UserPromptSubmit","prompt":"share this as a canvas","cwd":"%s"}' "$ROOT" \
    | CODEX_SESSION_ID="$RUN-$1" HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" \
      HQ_AUTO_SESSION_PROJECT=0 HQ_DISABLED_HOOKS=auto-session-project \
      bash "$ADAPTER" 2>/dev/null
}
DEFAULT_PREEXISTS=0
[ -f "$DEFAULT_LEDGER" ] && DEFAULT_PREEXISTS=1

echo "== 1. preflight is SessionStart-only, so a reactive policy must not appear =="
OUT_A="$( (cd "$ROOT" && bash core/scripts/codex-preflight.sh policies --session "$RUN-a") 2>/dev/null )"
if printf '%s' "$OUT_A" | grep -Fq "$SLUG"; then
  fail "preflight omits $SLUG (policy is reactive-only)" "slug present in the SessionStart pull path"
else
  ok "preflight omits $SLUG (policy is reactive-only)"
fi

echo "== 1a. Codex reactive path: two distinct sessions BOTH receive $SLUG =="
if [ -f "$ADAPTER" ]; then
  CX_A="$(codex_prompt cxa)"
  CX_B="$(codex_prompt cxb)"
  if printf '%s' "$CX_A" | grep -Fq "$SLUG"; then
    ok "Codex session A receives $SLUG on a matching prompt"
  else
    fail "Codex session A receives $SLUG on a matching prompt" \
      "slug missing; got: $(printf '%s' "$CX_A" | tr '\n' ' ' | cut -c1-300)"
  fi
  if printf '%s' "$CX_B" | grep -Fq "$SLUG"; then
    ok "Codex session B receives $SLUG (dedupe is per-session, not per-machine)"
  else
    fail "Codex session B receives $SLUG (dedupe is per-session, not per-machine)" \
      "slug missing — dedupe leaked across sessions"
  fi
else
  fail "Codex reactive path" "adapter missing at $ADAPTER"
fi
if [ "$DEFAULT_PREEXISTS" = 0 ] && [ -f "$DEFAULT_LEDGER" ]; then
  fail "preflight never touches the shared default.txt ledger" "default.txt was created"
else
  ok "preflight never touches the shared default.txt ledger"
fi

echo "== 1b. codex adapter synthesizes a session_id when the payload lacks one =="
if [ -f "$ADAPTER" ]; then
  AOUT="$(codex_prompt cx)"
  if printf '%s' "$AOUT" | grep -Fq "$SLUG" && [ -f "$LEDGER_DIR/codex-$RUN-cx.txt" ]; then
    ok "adapter injects $SLUG under a synthesized session ledger"
  else
    fail "adapter injects $SLUG under a synthesized session ledger" "output or ledger codex-$RUN-cx.txt missing"
  fi
  rm -f "$LEDGER_DIR/codex-$RUN-cx.txt" 2>/dev/null || true
else
  ok "codex adapter not present — skip"
fi

echo "== 2. .grok/rules pointer exists and is non-empty =="
GROK_RULE="$ROOT/.grok/rules/$SLUG.md"
if [ -s "$GROK_RULE" ]; then
  ok ".grok/rules/$SLUG.md present and non-empty"
else
  fail ".grok/rules/$SLUG.md present and non-empty" "missing or empty at $GROK_RULE"
fi
if grep -Fq "/deploy" "$GROK_RULE" 2>/dev/null && grep -Fq "canvas" "$GROK_RULE" 2>/dev/null; then
  ok "grok rule covers canvas-vs-/deploy distinction"
else
  fail "grok rule covers canvas-vs-/deploy distinction" "expected 'canvas' and '/deploy' mentions"
fi
if grep -Fq "explicitly requested local file" "$GROK_RULE" 2>/dev/null \
  && grep -Fq "native audited Slack upload helper" "$GROK_RULE" 2>/dev/null; then
  ok "grok rule permits explicitly requested local Slack attachments"
else
  fail "grok rule permits explicitly requested local Slack attachments" \
    "expected the scoped Slack-file exception and audited helper"
fi

echo "== 3. codex-skill-bridge.sh status regression smoke =="
# The exit code of `status` is environment state (e.g. "blocked" on checkouts
# without symlink support), not something this policy can regress — so assert
# the script still runs and reports, not a specific verdict.
BRIDGE="$ROOT/core/scripts/codex-skill-bridge.sh"
if [ -f "$BRIDGE" ]; then
  BOUT="$( (cd "$ROOT" && bash "$BRIDGE" status) 2>&1 )"
  if [ -n "$BOUT" ] && printf '%s' "$BOUT" | grep -Fq "bridge:"; then
    ok "codex-skill-bridge.sh status still reports bridge state"
  else
    fail "codex-skill-bridge.sh status still reports bridge state" "no report; got: $(printf '%s' "$BOUT" | tr '\n' ' ' | cut -c1-200)"
  fi
else
  ok "codex-skill-bridge.sh not present — skip"
fi

echo
echo "==== codex-preflight-policies: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ] || exit 1
