#!/usr/bin/env bash
# PATH-shim launch inventory for the Bash policy-write guard. Keep the common
# unrelated-command path within one external launch while proving that a real
# policy write still reaches the full deny scanner. The core guard is measured
# beside it because it owns core/policies and already has its own optimized path.
set -uo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
POLICY_HOOK="${HQ_TEST_POLICY_HOOK:-$ROOT/.claude/hooks/block-policy-writes-bash.sh}"
CORE_HOOK="${HQ_TEST_CORE_HOOK:-$ROOT/.claude/hooks/block-core-writes-bash.sh}"
BASH_BIN="$(command -v bash)"
ORIGINAL_PATH="$PATH"
REAL_JQ="$(PATH="$ORIGINAL_PATH" command -v jq 2>/dev/null || true)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
PROJECT="$TMP/hqroot"
mkdir -p "$BIN" "$PROJECT/personal/policies" "$PROJECT/core/policies" "$PROJECT/core"
printf 'rules:\n  exclude: []\n' > "$PROJECT/core/core.yaml"
: > "$TMP/process.log"
export PROCESS_LOG="$TMP/process.log"

[ -n "$REAL_JQ" ] || { echo 'FAIL: jq is required by the guard' >&2; exit 1; }
[ -x "$POLICY_HOOK" ] || { echo "FAIL: missing policy hook: $POLICY_HOOK" >&2; exit 1; }
[ -x "$CORE_HOOK" ] || { echo "FAIL: missing core hook: $CORE_HOOK" >&2; exit 1; }

# These are the external programs reachable from the two hooks and the shared
# parser. Wrappers log one line then exec the original binary, so counts are
# portable and do not depend on strace or platform-specific tracing.
for program in cat jq dirname sed grep awk uname tr yq node cygpath realpath readlink; do
  real="$(PATH="$ORIGINAL_PATH" command -v "$program" 2>/dev/null || true)"
  [ -n "$real" ] || continue
  printf -v real_quoted '%q' "$real"
  printf '#!/bin/bash\nprintf "%%s\\n" "%s" >> "$PROCESS_LOG"\nexec %s "$@"\n' \
    "$program" "$real_quoted" > "$BIN/$program"
  chmod 700 "$BIN/$program"
done

FAIL=0
pass() { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

total_launches() {
  local count=0 line
  while IFS= read -r line; do count=$((count + 1)); done < "$PROCESS_LOG"
  printf '%s' "$count"
}

print_inventory() {
  local program count line
  for program in cat jq dirname sed grep awk uname tr yq node cygpath realpath readlink; do
    count=0
    while IFS= read -r line; do
      [ "$line" = "$program" ] && count=$((count + 1))
    done < "$PROCESS_LOG"
    [ "$count" -eq 0 ] || printf '%s=%s ' "$program" "$count"
  done
}

run_guard() {
  local hook="$1" payload="$2" rc=0
  : > "$PROCESS_LOG"
  printf '%s' "$payload" | PATH="$BIN:$ORIGINAL_PATH" CLAUDE_PROJECT_DIR="$PROJECT" \
    "$BASH_BIN" "$hook" > "$TMP/stdout" 2> "$TMP/stderr" || rc=$?
  GUARD_RC="$rc"
}

run_policy_dispatched() {
  local hook="$1" command_text="$2" payload rc=0
  payload="$(jq -cn --arg cwd "$PROJECT" --arg command "$command_text" \
    '{tool_name:"Bash",cwd:$cwd,session_id:"budget-test",tool_input:{command:$command}}')"
  : > "$PROCESS_LOG"
  env PATH="$BIN:$ORIGINAL_PATH" CLAUDE_PROJECT_DIR="$PROJECT" \
    HQ_CHECKPOINT_RUNTIME=claude HQ_HOOK_EVENT=PreToolUse HQ_HOOK_TOOL_NAME=Bash \
    HQ_HOOK_COMMAND="$command_text" HQ_HOOK_CWD="$PROJECT" \
    HQ_HOOK_SESSION_ID=budget-test HQ_LIB_WINSEP=1 PROCESS_LOG="$PROCESS_LOG" \
    "$BASH_BIN" "$hook" drain PreToolUse <<< "$payload" \
    > "$TMP/stdout" 2> "$TMP/stderr" || rc=$?
  GUARD_RC="$rc"
}

policy_normal='{"tool_input":{"command":"git status"}}'
run_guard "$POLICY_HOOK" "$policy_normal"
policy_normal_total="$(total_launches)"
printf 'block-policy-writes ordinary PreToolUse execve_total=%s inventory=%s\n' \
  "$policy_normal_total" "$(print_inventory)"
if [ "$GUARD_RC" -eq 0 ] && [ "$policy_normal_total" -le 1 ] \
   && [ ! -s "$TMP/stdout" ] && [ ! -s "$TMP/stderr" ]; then
  pass 'ordinary policy-guard command stays silent within one launch'
else
  fail "ordinary policy-guard launch budget exceeded 1 or behavior changed (rc=$GUARD_RC, launches=$policy_normal_total)"
fi

# Match the dispatcher-backed ordinary path (which reuses HQ_HOOK_COMMAND) and
# slow candidate-scan path. The separate core script test used to duplicate
# this PATH-shim inventory.
run_policy_dispatched "$POLICY_HOOK" 'git status'
policy_dispatched_total="$(total_launches)"
printf 'block-policy-writes dispatched ordinary PreToolUse execve_total=%s inventory=%s\n' \
  "$policy_dispatched_total" "$(print_inventory)"
if [ "$GUARD_RC" -eq 0 ] && [ "$policy_dispatched_total" -eq 0 ] \
   && [ ! -s "$TMP/stdout" ] && [ ! -s "$TMP/stderr" ]; then
  pass 'dispatcher-backed ordinary path stays within zero launches'
else
  fail "dispatcher-backed ordinary path exceeded zero launches or behavior changed (rc=$GUARD_RC, launches=$policy_dispatched_total)"
fi

run_policy_dispatched "$POLICY_HOOK" 'printf policies'
policy_candidate_total="$(total_launches)"
printf 'block-policy-writes candidate scan PreToolUse execve_total=%s inventory=%s\n' \
  "$policy_candidate_total" "$(print_inventory)"
if [ "$GUARD_RC" -eq 0 ] && [ "$policy_candidate_total" -le 2 ] \
   && [ ! -s "$TMP/stdout" ] && [ ! -s "$TMP/stderr" ]; then
  pass 'candidate-scan path stays within two launches'
else
  fail "candidate-scan launch budget exceeded 2 or behavior changed (rc=$GUARD_RC, launches=$policy_candidate_total)"
fi

policy_write="$(printf 'cat > \"%s\"\n' "$PROJECT/personal/policies/new.md" \
  | jq -Rs '{tool_input:{command:.}}')"
run_guard "$POLICY_HOOK" "$policy_write"
policy_write_total="$(total_launches)"
printf 'block-policy-writes policy-write inspection execve_total=%s inventory=%s\n' \
  "$policy_write_total" "$(print_inventory)"
if [ "$GUARD_RC" -eq 2 ] && grep -q '^BLOCKED: Bash command appears to write a policy file\.' "$TMP/stderr"; then
  pass 'a direct policy write remains denied after the fast path'
else
  fail "policy write was not denied with its diagnostic (rc=$GUARD_RC)"
fi

core_normal='{"tool_input":{"command":"git status"}}'
run_guard "$CORE_HOOK" "$core_normal"
core_normal_total="$(total_launches)"
printf 'block-core-writes ordinary PreToolUse execve_total=%s inventory=%s\n' \
  "$core_normal_total" "$(print_inventory)"
if [ "$GUARD_RC" -eq 0 ] && [ "$core_normal_total" -le 2 ] \
   && [ ! -s "$TMP/stdout" ] && [ ! -s "$TMP/stderr" ]; then
  pass 'the existing core-guard fast path stays within two launches'
else
  fail "core-guard ordinary launch budget exceeded 2 or behavior changed (rc=$GUARD_RC, launches=$core_normal_total)"
fi

core_write="$(printf 'cat > \"%s\"\n' "$PROJECT/core/policies/new.md" \
  | jq -Rs '{tool_input:{command:.}}')"
run_guard "$CORE_HOOK" "$core_write"
core_write_total="$(total_launches)"
printf 'block-core-writes core-write inspection execve_total=%s inventory=%s\n' \
  "$core_write_total" "$(print_inventory)"
if [ "$GUARD_RC" -eq 2 ] && grep -q '^BLOCKED: Bash command appears to write into protected scaffold paths\.' "$TMP/stderr"; then
  pass 'a direct core policy write remains denied'
else
  fail "core policy write was not denied with its diagnostic (rc=$GUARD_RC)"
fi

exit "$FAIL"
