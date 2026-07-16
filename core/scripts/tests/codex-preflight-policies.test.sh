#!/usr/bin/env bash
# codex-preflight-policies.test.sh — US-002 acceptance battery for the
# cross-runtime reach of core/policies/hq-prefer-native-capabilities.md.
#
# Codex has no push injection: `core/scripts/codex-preflight.sh policies` is
# the pull path — it re-runs .claude/hooks/inject-policy-on-trigger.sh with a
# synthetic SessionStart payload, so any on:[SessionStart] policy in
# core/policies/ must surface through it. Asserts:
#   1. `codex-preflight.sh policies` output contains hq-prefer-native-capabilities.
#   2. .grok/rules/hq-prefer-native-capabilities.md exists and is non-empty
#      (Grok auto-scans .grok/rules/ — the Grok-side pointer).
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
trap 'rm -f "$LEDGER_DIR/$RUN-a.txt" "$LEDGER_DIR/$RUN-b.txt" "$LEDGER_DIR/$RUN-cx.txt" 2>/dev/null || true' EXIT
DEFAULT_PREEXISTS=0
[ -f "$DEFAULT_LEDGER" ] && DEFAULT_PREEXISTS=1

echo "== 1. preflight policies: two distinct sessions BOTH emit $SLUG =="
OUT_A="$( (cd "$ROOT" && bash core/scripts/codex-preflight.sh policies --session "$RUN-a") 2>/dev/null )"
OUT_B="$( (cd "$ROOT" && bash core/scripts/codex-preflight.sh policies --session "$RUN-b") 2>/dev/null )"
if printf '%s' "$OUT_A" | grep -Fq "$SLUG"; then
  ok "session A emits $SLUG"
else
  fail "session A emits $SLUG" "slug missing; got: $(printf '%s' "$OUT_A" | tr '\n' ' ' | cut -c1-300)"
fi
if printf '%s' "$OUT_B" | grep -Fq "$SLUG"; then
  ok "session B emits $SLUG (dedupe is per-session, not per-machine)"
else
  fail "session B emits $SLUG (dedupe is per-session, not per-machine)" "slug missing — dedupe leaked across sessions"
fi
if [ "$DEFAULT_PREEXISTS" = 0 ] && [ -f "$DEFAULT_LEDGER" ]; then
  fail "preflight never touches the shared default.txt ledger" "default.txt was created"
else
  ok "preflight never touches the shared default.txt ledger"
fi

echo "== 1b. codex adapter synthesizes a session_id when the payload lacks one =="
ADAPTER="$ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
if [ -f "$ADAPTER" ]; then
  AOUT="$(printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$ROOT" \
    | CODEX_SESSION_ID="$RUN-cx" HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$ADAPTER" 2>/dev/null)"
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
