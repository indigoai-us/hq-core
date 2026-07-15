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
# The session-less preflight payload maps to the shared default.txt dedupe
# ledger (a TRACKED file), and the hook appends every fired slug to it — so
# the ledger is backed up before the run and byte-restored after, leaving the
# working tree clean.
#
# Explicitly wired into .github/workflows/pr-checks.yml — tests here are NOT
# auto-discovered (indigo-hq-core-staging-pr-mechanics rule 3).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SLUG="hq-prefer-native-capabilities"
LEDGER="$ROOT/workspace/orchestrator/policy-trigger-state/default.txt"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

# Back up the shared dedupe ledger; restore it exactly on exit.
BACKUP=""
if [ -f "$LEDGER" ]; then
  BACKUP="$(mktemp)"
  cp "$LEDGER" "$BACKUP"
  trap '[ -n "$BACKUP" ] && cp "$BACKUP" "$LEDGER" && rm -f "$BACKUP"' EXIT
else
  trap 'rm -f "$LEDGER"' EXIT
fi
# Neutralize prior state so dedupe can never suppress the slug for this run.
rm -f "$LEDGER"

echo "== 1. codex-preflight.sh policies emits $SLUG =="
OUT="$( (cd "$ROOT" && bash core/scripts/codex-preflight.sh policies) 2>/dev/null )"
if printf '%s' "$OUT" | grep -Fq "$SLUG"; then
  ok "preflight policies emits $SLUG"
else
  fail "preflight policies emits $SLUG" "slug missing; got: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-300)"
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
