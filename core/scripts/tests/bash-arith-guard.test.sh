#!/usr/bin/env bash
# Decision-only coverage of the arithmetic helper; no payload is executed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
. "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh"
passed=0 failed=0
arith_case() {
  local expected="$1" label="$2" command="$3" actual=0
  hq_arith_guard_check "$command" || actual=2
  if [ "$actual" = "$expected" ]; then
    passed=$((passed + 1))
  else
    printf 'FAIL %s: want %s got %s (%s)\n' "$label" "$expected" "$actual" "$HQ_ARITH_GUARD_REASON"
    failed=$((failed + 1))
  fi
}
. "$ROOT/core/scripts/tests/bash-arith-guard.cases.sh"
# Arithmetic-only: an expansion as the whole bash -c program has no arithmetic
# to check. The full hook stack still refuses it (mandatory scope authorizer:
# unset variable in a -c program); mandatory-scope-authorizer.test.sh asserts that.
arith_case 0 env-split-review-087 'bash -c "$CMD"'

# Nested substitutions are scanned once per level. Each decision must finish
# well inside the hook's time budget; the scan once grew exponentially and
# took tens of seconds at the deepest nesting the guard accepts.
nested_text() { # OPEN DEPTH
  local text="echo x" level=0
  while [ "$level" -lt "$2" ]; do text="cat $1$text)"; level=$((level + 1)); done
  # The quoted data keeps the guard off its no-arithmetic fast path.
  printf "%s '((x))'" "$text"
}
timed_case() {
  local expected="$1" label="$2" command="$3" actual=0
  SECONDS=0
  hq_arith_guard_check "$command" || actual=2
  if [ "$actual" = "$expected" ] && [ "$SECONDS" -le 5 ]; then
    passed=$((passed + 1))
  else
    printf 'FAIL %s: want %s within 5s, got %s after %ss (%s)\n' "$label" "$expected" "$actual" "$SECONDS" "$HQ_ARITH_GUARD_REASON"
    failed=$((failed + 1))
  fi
}
timed_case 0 timing-nested-process-input "$(nested_text '<(' 16)"
timed_case 0 timing-nested-process-output "$(nested_text '>(' 16)"
timed_case 0 timing-nested-command-substitution "$(nested_text '$(' 16)"
timed_case 2 timing-nested-past-limit "$(nested_text '<(' 24)"
alternating="echo x"
level=0
while [ "$level" -lt 16 ]; do
  if [ $((level % 2)) = 0 ]; then alternating="cat <($alternating)"; else alternating="echo \$($alternating)"; fi
  level=$((level + 1))
done
timed_case 0 timing-nested-alternating "$alternating '((x))'"
unclosed=""
level=0
while [ "$level" -lt 200 ]; do unclosed+="cat <("; level=$((level + 1)); done
timed_case 2 timing-unclosed-process "$unclosed echo x '((x))'"
printf 'arithmetic guard: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
