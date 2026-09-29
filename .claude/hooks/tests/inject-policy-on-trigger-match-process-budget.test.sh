#!/usr/bin/env bash
# PreToolUse Bash policy matching must stay within a portable total process budget.
# PATH shims count each external command; no strace or platform-specific tool is needed.
set -euo pipefail

TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
HOOK_SOURCE="${HQ_INJECT_POLICY_TEST_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
[ -f "$HOOK_SOURCE" ] || { echo "FAIL: hook source is missing: $HOOK_SOURCE" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/inject-policy-match-budget.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SHIM_DIR="$TMP/bin"
mkdir -p "$TMP/.claude/hooks" "$TMP/core" "$SHIM_DIR"
cp "$HOOK_SOURCE" "$TMP/.claude/hooks/inject-policy-on-trigger.sh"
ln -s "$ROOT/core/scripts" "$TMP/core/scripts"
ln -s "$ROOT/core/policies" "$TMP/core/policies"

POLICY_COUNT=0
for policy in "$TMP/core/policies"/*.md; do
  [ -f "$policy" ] || continue
  case "${policy##*/}" in
    example-policy.md|README.md|*" "*|*.sync-conflict-*.md|*.conflict-*) continue ;;
  esac
  POLICY_COUNT=$((POLICY_COUNT + 1))
done
[ "$POLICY_COUNT" -ge 100 ] || {
  echo "FAIL: expected a realistic core policy set (at least 100 files), found $POLICY_COUNT" >&2
  exit 1
}

PROCESS_LOG="$TMP/processes.log"
: > "$PROCESS_LOG"
TOOLS="awk bash cat date dirname git grep iconv jq mkdir mktemp mv openssl rm rmdir sha256sum shasum sleep sort stat touch uname wc"
for tool in $TOOLS; do
  real_tool="$(type -P "$tool" 2>/dev/null || true)"
  [ -n "$real_tool" ] || continue
  printf '#!/bin/bash\nprintf "%%s\\n" %q >> "$HQ_PROCESS_TRACE_FILE"\nexec %q "$@"\n' \
    "$tool" "$real_tool" > "$SHIM_DIR/$tool"
  chmod +x "$SHIM_DIR/$tool"
done

PAYLOAD="$(jq -cn --arg cwd "$TMP" '{hook_event_name:"PreToolUse",session_id:"policy-match-budget",tool_name:"Bash",cwd:$cwd,tool_input:{command:"true"}}')"
unset BASH_ENV ENV HQ_POLICY_WORKER_DIR
set +e
PATH="$SHIM_DIR" HQ_PROCESS_TRACE_FILE="$PROCESS_LOG" HOME="$TMP/home" \
  XDG_STATE_HOME="$TMP/home/.local/state" HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  HQ_HOOK_PROFILE=standard HQ_HOOK_TIMEOUT_SENTRY=0 \
  bash "$TMP/.claude/hooks/inject-policy-on-trigger.sh" \
  <<<"$PAYLOAD" >"$TMP/hook.out" 2>"$TMP/hook.err"
HOOK_RC=$?
set -e
[ "$HOOK_RC" -eq 0 ] || {
  echo "FAIL: hook exited $HOOK_RC" >&2
  tail -200 "$TMP/hook.err" >&2
  exit 1
}

TOTAL_COUNT=0
PROGRAMS=()
COUNTS=()
PROGRAM_COUNT=0
while IFS= read -r program; do
  [ -n "$program" ] || continue
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  found=0
  for ((program_index=0; program_index<PROGRAM_COUNT; program_index++)); do
    if [ "${PROGRAMS[$program_index]}" = "$program" ]; then
      COUNTS[$program_index]=$((COUNTS[$program_index] + 1))
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    PROGRAMS[$PROGRAM_COUNT]="$program"
    COUNTS[$PROGRAM_COUNT]=1
    PROGRAM_COUNT=$((PROGRAM_COUNT + 1))
  fi
done < "$PROCESS_LOG"

PROGRAM_SUMMARY=""
for ((program_index=0; program_index<PROGRAM_COUNT; program_index++)); do
  PROGRAM_SUMMARY+=" ${PROGRAMS[$program_index]}=${COUNTS[$program_index]}"
done
PROCESS_BUDGET=32
[ "$TOTAL_COUNT" -le "$PROCESS_BUDGET" ] || {
  echo "FAIL: $TOTAL_COUNT total hook process launches over $POLICY_COUNT core policies (budget: $PROCESS_BUDGET);$PROGRAM_SUMMARY" >&2
  exit 1
}

printf 'PASS: %s core policies, %s total hook process launches (budget: %s);%s\n' \
  "$POLICY_COUNT" "$TOTAL_COUNT" "$PROCESS_BUDGET" "$PROGRAM_SUMMARY"
