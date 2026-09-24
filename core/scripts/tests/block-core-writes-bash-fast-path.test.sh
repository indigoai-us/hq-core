#!/usr/bin/env bash
# Count expensive hook operations directly; timing is too noisy for a guard
# that runs before every shell action.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="${HQ_TEST_BLOCK_CORE_WRITES_HOOK:-$ROOT/.claude/hooks/block-core-writes-bash.sh}"
REAL_BASH="$(command -v bash)"
REAL_JQ="$(command -v jq)" || { echo 'FAIL: jq is required for this regression test' >&2; exit 1; }
REAL_AWK="$(command -v awk)" || { echo 'FAIL: awk is required for this regression test' >&2; exit 1; }
REAL_SED="$(command -v sed)" || { echo 'FAIL: sed is required for this regression test' >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/block-core-fast-path.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
BIN="$TMP/bin"
mkdir -p "$FIX/.claude" "$FIX/core" "$BIN"
printf '{}\n' > "$FIX/.claude/settings.local.json"
printf 'rules:\n  exclude: []\n' > "$FIX/core/core.yaml"

export HQ_TEST_OPERATION_LOG="$TMP/operations.log"
export HQ_TEST_REAL_JQ="$REAL_JQ"
export HQ_TEST_REAL_AWK="$REAL_AWK"
export HQ_TEST_REAL_SED="$REAL_SED"
cat > "$BIN/jq" <<'EOF'
#!/bin/sh
printf 'jq\n' >> "$HQ_TEST_OPERATION_LOG"
exec "$HQ_TEST_REAL_JQ" "$@"
EOF
cat > "$BIN/awk" <<'EOF'
#!/bin/sh
printf 'awk\n' >> "$HQ_TEST_OPERATION_LOG"
exec "$HQ_TEST_REAL_AWK" "$@"
EOF
cat > "$BIN/sed" <<'EOF'
#!/bin/sh
printf 'sed\n' >> "$HQ_TEST_OPERATION_LOG"
exec "$HQ_TEST_REAL_SED" "$@"
EOF
cat > "$BIN/yq" <<'EOF'
#!/bin/sh
printf 'yq\n' >> "$HQ_TEST_OPERATION_LOG"
exit 0
EOF
chmod +x "$BIN/jq" "$BIN/awk" "$BIN/sed" "$BIN/yq"

FAIL=0
LAST_COUNTS=''
LAST_RC=0

operation_counts() {
  local op
  local jq_count=0 awk_count=0 yq_count=0 sed_count=0
  while IFS= read -r op; do
    case "$op" in
      jq) jq_count=$((jq_count + 1)) ;;
      awk) awk_count=$((awk_count + 1)) ;;
      yq) yq_count=$((yq_count + 1)) ;;
      sed) sed_count=$((sed_count + 1)) ;;
    esac
  done < "$HQ_TEST_OPERATION_LOG"
  LAST_COUNTS="jq=$jq_count awk=$awk_count yq=$yq_count sed=$sed_count"
}

run_hook() {
  local input="$1" rc=0
  : > "$HQ_TEST_OPERATION_LOG"
  if printf '%s' "$input" | env \
    BASH_ENV=/dev/null \
    CLAUDE_PROJECT_DIR="$FIX" \
    PATH="$BIN:$PATH" \
    "$REAL_BASH" "$HOOK" >/dev/null 2>"$TMP/hook.err"; then
    rc=0
  else
    rc=$?
  fi
  operation_counts
  LAST_RC="$rc"
}

assert_case() {
  local label="$1" expected_rc="$2" input="$3" expected_counts="$4" rc
  run_hook "$input"
  rc="$LAST_RC"
  if [ "$rc" -ne "$expected_rc" ]; then
    printf 'FAIL [%s]: expected exit %s, got %s\n' "$label" "$expected_rc" "$rc" >&2
    FAIL=1
  fi
  if [ "$LAST_COUNTS" != "$expected_counts" ]; then
    printf 'FAIL [%s]: expected %s, got %s\n' "$label" "$expected_counts" "$LAST_COUNTS" >&2
    FAIL=1
  fi
  printf '%s: exit=%s %s\n' "$label" "$rc" "$LAST_COUNTS"
}

# shellcheck disable=SC2016 # jq's $cmd is a jq variable, not a shell variable.
safe_payload="$($REAL_JQ -cn --arg cmd 'echo hi' '{tool_input:{command:$cmd}}')"
# shellcheck disable=SC2016 # jq's $cmd is a jq variable, not a shell variable.
protected_payload="$($REAL_JQ -cn --arg cmd "touch $FIX/core/probe.txt" '{tool_input:{command:$cmd}}')"
assert_case 'benign command skips protected-path machinery' 0 "$safe_payload" 'jq=1 awk=0 yq=0 sed=0'
assert_case 'protected write parses once and keeps the deny' 2 "$protected_payload" 'jq=2 awk=1 yq=1 sed=0'

# Payloads without a string command keep the guard's long-standing allow
# decision: the Grok adapter sends tool_input without a command key when its
# extracted command is empty, so these must not become denials.
assert_case 'malformed hook JSON stays allowed' 0 'not-json' 'jq=1 awk=0 yq=0 sed=0'
assert_case 'missing command field stays allowed' 0 '{}' 'jq=1 awk=0 yq=0 sed=0'
assert_case 'empty tool_input stays allowed' 0 '{"tool_input":{}}' 'jq=1 awk=0 yq=0 sed=0'

# shellcheck disable=SC2016 # Search for literal shell syntax in the hook.
if grep -Fq '$(strip_token_quotes' "$HOOK"; then
  echo 'FAIL: token quote stripping still starts one subshell per word' >&2
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
echo 'block-core-writes-bash-fast-path: PASS'
