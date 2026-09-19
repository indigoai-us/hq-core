#!/usr/bin/env bash
# hq-core: public
# Regression for DEF-026: block-env-dump.sh must fire on the live PreToolUse
# path (hook-gate + master-hook) under every profile, not only when invoked
# directly. Token-shaped strings, if any, are assembled from fragments.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="$ROOT/.claude/hooks/block-env-dump.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
CURSOR_RULE="$ROOT/.cursor/rules/hq.mdc"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }
[ -f "$HOOK" ] || { echo "FAIL: missing $HOOK" >&2; exit 1; }
[ -f "$GATE" ] || { echo "FAIL: missing $GATE" >&2; exit 1; }
[ -f "$MASTER" ] || { echo "FAIL: missing $MASTER" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/block-env-dump.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

payload() {
  jq -nc --arg c "$1" --arg root "$ROOT" \
    '{session_id:"block-env-dump-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$c}}'
}

run_hook() { # cmd -> rc
  local rc=0
  payload "$1" | bash "$HOOK" >/dev/null 2>"$TMP/err" || rc=$?
  printf '%s' "$rc"
}

expect_hook() {
  local want="$1" desc="$2" cmd="$3"
  local got
  got="$(run_hook "$cmd")"
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc (want $want got $got; err=$(tr '\n' ' ' < "$TMP/err"))"
  fi
}

echo "[1] hook body: dumps block, allowed forms pass"
expect_hook 2 "bare printenv blocks" "printenv"
expect_hook 2 "bare env blocks" "env"
expect_hook 2 "env piped to grep -c blocks" "env | grep -c ."
expect_hook 2 "printenv piped blocks" "printenv | wc -l"
expect_hook 2 "set with no args blocks" "set"
expect_hook 2 "export -p blocks" "export -p"
expect_hook 2 "declare -x dump blocks" "declare -x"
expect_hook 2 "cat /proc/self/environ blocks" "cat /proc/self/environ"
expect_hook 0 "printenv HOME allowed" "printenv HOME"
expect_hook 0 "env VAR=x cmd allowed" "env FOO=bar ls"
expect_hook 0 "benign ls allowed" "ls"
expect_hook 0 "set -e allowed" "set -euo pipefail"
expect_hook 0 "export assignment allowed" "export FOO=bar"
expect_hook 0 "unrelated tool ignored" "true"

# Non-Bash payload must fail open (registration is not the only scope boundary).
rc=0
jq -nc '{tool_name:"Read",tool_input:{file_path:"/tmp/x"}}' \
  | bash "$HOOK" >/dev/null 2>"$TMP/err" || rc=$?
[ "$rc" = "0" ] && ok "non-Bash tool is ignored" || bad "non-Bash tool want 0 got $rc"

echo "[2] hook-gate: every profile blocks printenv and allows ls / printenv HOME"
for p in minimal standard strict; do
  for case_spec in "printenv:2" "ls:0" "printenv HOME:0"; do
    cmd="${case_spec%:*}"; want="${case_spec##*:}"
    rc=0
    payload "$cmd" \
      | HQ_HOOK_PROFILE="$p" HQ_HOOK_TIMEOUT_SENTRY=0 CLAUDE_PROJECT_DIR="$ROOT" \
        bash "$GATE" block-env-dump "$HOOK" >/dev/null 2>"$TMP/err" || rc=$?
    if [ "$rc" = "$want" ]; then
      ok "hook-gate profile=$p cmd=$(printf '%s' "$cmd" | tr ' ' _) rc=$rc"
    else
      bad "hook-gate profile=$p cmd=$cmd want $want got $rc err=$(tr '\n' ' ' < "$TMP/err")"
    fi
  done
done

echo "[3] master-hook PreToolUse: every profile blocks printenv and allows ls / printenv HOME"
export CLAUDE_PROJECT_DIR="$ROOT"
export HQ_HOOK_TIMEOUT_SENTRY=0
export HQ_ALLOW_HQ_WORKTREE=1
for p in minimal standard strict; do
  for case_spec in "printenv:2" "ls:0" "printenv HOME:0"; do
    cmd="${case_spec%:*}"; want="${case_spec##*:}"
    rc=0
    payload "$cmd" \
      | HQ_HOOK_PROFILE="$p" bash "$MASTER" PreToolUse >/dev/null 2>"$TMP/err" || rc=$?
    if [ "$rc" = "$want" ]; then
      ok "master-hook profile=$p cmd=$(printf '%s' "$cmd" | tr ' ' _) rc=$rc"
    else
      bad "master-hook profile=$p cmd=$cmd want $want got $rc err=$(tr '\n' ' ' < "$TMP/err")"
    fi
  done
done

echo "[4] Cursor scaffold (DEF-002)"
if [ -f "$CURSOR_RULE" ] && grep -q '.claude/CLAUDE.md' "$CURSOR_RULE"; then
  ok ".cursor/rules/hq.mdc references .claude/CLAUDE.md"
else
  bad "missing or incomplete Cursor rule at $CURSOR_RULE"
fi
if grep -Fqx '    - .cursor/' "$ROOT/core/core.yaml"; then
  ok "core.yaml locked includes .cursor/"
else
  bad "core.yaml locked list missing .cursor/"
fi
if grep -Fqx '    - .cursor' "$ROOT/core/core.yaml"; then
  ok "core.yaml replace_from_staging includes .cursor"
else
  bad "core.yaml replace_from_staging missing .cursor"
fi

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS: block-env-dump ($pass)"
  exit 0
fi
echo "FAILURES: block-env-dump ($fail failed, $pass passed)" >&2
exit 1
