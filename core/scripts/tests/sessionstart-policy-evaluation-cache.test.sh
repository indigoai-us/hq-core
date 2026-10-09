#!/usr/bin/env bash
# SessionStart evaluation results should be reusable across sessions when all
# evaluator inputs match. Call counts, rather than wall time, make this stable.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK_SOURCE="${HQ_TEST_HOOK_SOURCE:-$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh}"
TMP="$(mktemp -d)"
ROOT="$TMP/hq"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$ROOT/.claude/hooks" "$ROOT/core/scripts" "$ROOT/core/policies" \
  "$ROOT/personal/policies" "$ROOT/workspace" "$TMP/bin" "$TMP/home"
cp "$HOOK_SOURCE" "$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
cp "$HQ_SRC/core/scripts/hook-lib.sh" "$ROOT/core/scripts/hook-lib.sh"
cp "$HQ_SRC/core/scripts/eval-trigger.sh" "$ROOT/core/scripts/eval-trigger.sh"
cat > "$ROOT/core/scripts/derive-trigger-facts.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${HQ_TEST_FACTS:-always}"
SH
cat > "$ROOT/core/policies/sessionstart-cache.md" <<'POLICY'
---
id: sessionstart-cache-fixture
title: SessionStart evaluation cache fixture
scope: test
when: always
on: [SessionStart]
enforcement: soft
---

## Rule

SessionStart fixture policy rule.
POLICY
cat > "$TMP/bin/awk" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = 'EVENT=SessionStart' ]; then
    printf 'evaluation\n' >> "$HQ_TEST_AWK_CALLS"
    break
  fi
done
exec "$HQ_TEST_REAL_AWK" "$@"
SH
chmod +x "$TMP/bin/awk"

HQ_TEST_REAL_AWK="$(command -v awk)"
HQ_TEST_AWK_CALLS="$TMP/awk-calls.log"
: > "$HQ_TEST_AWK_CALLS"
export HQ_TEST_REAL_AWK HQ_TEST_AWK_CALLS

run_session() {
  local session="$1" output="$2" facts="${3:-always}" status=0
  printf '{"hook_event_name":"SessionStart","session_id":"%s","cwd":"%s"}\n' \
    "$session" "$ROOT" |
    env HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" HOME="$TMP/home" \
      XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:/usr/bin:/bin" \
      HQ_TEST_FACTS="$facts" \
      BASH_ENV=/dev/null bash "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" \
      > "$output" 2> "$output.stderr" || status=$?
  [ "$status" -eq 0 ] || fail "hook exited $status: $(cat "$output.stderr")"
}

run_session first "$TMP/first.out"
first_calls="$(wc -l < "$HQ_TEST_AWK_CALLS" | tr -d ' ')"
[ "$first_calls" -eq 1 ] || fail "expected one SessionStart evaluator call on first session, got $first_calls; output: $(cat "$TMP/first.out"); stderr: $(cat "$TMP/first.out.stderr")"
grep -Fq 'SessionStart fixture policy rule.' "$TMP/first.out" \
  || fail "fixture policy was not emitted: $(cat "$TMP/first.out")"

run_session second "$TMP/second.out"
second_calls="$(wc -l < "$HQ_TEST_AWK_CALLS" | tr -d ' ')"
[ "$second_calls" -eq $((first_calls + 1)) ] \
  || fail "expected a new-session evaluation to seed the shared result, got $first_calls -> $second_calls calls"
run_session third "$TMP/third.out"
third_calls="$(wc -l < "$HQ_TEST_AWK_CALLS" | tr -d ' ')"
[ "$third_calls" -eq "$second_calls" ] \
  || fail "third identical SessionStart launched evaluator again ($second_calls -> $third_calls calls)"
cmp -s "$TMP/second.out" "$TMP/third.out" \
  || fail "cross-session evaluation cache changed emitted output"

run_session changed-facts "$TMP/changed-facts.out" never
changed_calls="$(wc -l < "$HQ_TEST_AWK_CALLS" | tr -d ' ')"
[ "$changed_calls" -eq $((third_calls + 1)) ] \
  || fail "changed facts reused a stale evaluation result ($third_calls -> $changed_calls calls)"
[ ! -s "$TMP/changed-facts.out" ] \
  || fail "policy matched after the SessionStart facts changed: $(cat "$TMP/changed-facts.out")"

printf 'PASS: identical SessionStart evaluation is reused across sessions; changed facts invalidate the result\n'
