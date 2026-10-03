#!/usr/bin/env bash
# A contended per-session policy ledger must not hold SessionStart beyond its lock budget.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/inject-policy-lock-deadline.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
[ -f "$HOOK" ] || fail "hook missing: $HOOK"
PERL_BIN="$(command -v perl || true)"
[ -n "$PERL_BIN" ] || fail 'perl is required for the portable fixed-deadline wrapper'
REAL_STAT="$(command -v stat || true)"
[ -n "$REAL_STAT" ] || fail 'stat is required'

make_fixture() {
  local root="$1"
  mkdir -p "$root/core/policies" "$root/personal/policies" \
    "$root/workspace/orchestrator/policy-trigger-state" \
    "$root/workspace/orchestrator/hook-state"
  cat > "$root/core/policies/session-start-lock-test.md" <<'POLICY'
---
id: session-start-lock-test
title: "Session start lock test"
when: always
on: [SessionStart]
enforcement: hard
---

## Rule

LOCK_DEADLINE_NORMAL_POLICY_MARKER
POLICY
}

INPUT='{"hook_event_name":"SessionStart","session_id":"lock-deadline-check"}'
EXPECTED_ROOT="$TMP/expected-hq"
LOCKED_ROOT="$TMP/locked-hq"
TOOLS="$TMP/tools"
mkdir -p "$TOOLS"
make_fixture "$EXPECTED_ROOT"
make_fixture "$LOCKED_ROOT"

# Establish the unchanged normal output in an uncontended fixture.
env HQ_ROOT="$EXPECTED_ROOT" CLAUDE_PROJECT_DIR="$EXPECTED_ROOT" \
  bash "$HOOK" <<<"$INPUT" > "$TMP/expected.out" 2> "$TMP/expected.err" \
  || fail 'uncontended SessionStart did not complete'
case "$(cat "$TMP/expected.out")" in
  *LOCK_DEADLINE_NORMAL_POLICY_MARKER*) ;;
  *) fail 'uncontended SessionStart did not emit the normal policy content' ;;
esac

# Hold the exact per-session dedupe lock and make each external stat call slow.
# On the base, the 200-attempt loop takes longer than the fixed 4-second ceiling.
LEDGER="$LOCKED_ROOT/workspace/orchestrator/policy-trigger-state/lock-deadline-check.txt"
mkdir -p "${LEDGER}.lock"
printf '%s\n' 99999999 > "${LEDGER}.lock/pid"
cat > "$TOOLS/stat" <<'STAT'
#!/usr/bin/env bash
sleep "${INJECT_POLICY_TEST_STAT_DELAY:-0.05}"
exec "$INJECT_POLICY_TEST_REAL_STAT" "$@"
STAT
chmod +x "$TOOLS/stat"
status=0
"$PERL_BIN" -e 'alarm shift; exec @ARGV or exit 127' 4 \
  env PATH="$TOOLS:$PATH" INJECT_POLICY_TEST_REAL_STAT="$REAL_STAT" \
  INJECT_POLICY_TEST_STAT_DELAY=0.05 HQ_ROOT="$LOCKED_ROOT" \
  CLAUDE_PROJECT_DIR="$LOCKED_ROOT" bash "$HOOK" <<<"$INPUT" \
  > "$TMP/locked.out" 2> "$TMP/locked.err" || status=$?
[ "$status" -eq 0 ] || fail "contended SessionStart did not finish inside 4 seconds (exit $status)"
cmp -s "$TMP/expected.out" "$TMP/locked.out" \
  || fail 'contended SessionStart changed the normal injected policy output'
printf 'PASS: contended SessionStart finishes within 4 seconds and preserves normal policy output\n'
