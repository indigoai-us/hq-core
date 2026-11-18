#!/usr/bin/env bash
# hq-core: public
# credential-read-guard-time-budget.test.sh — block-credential-file-read.sh
# stops a long Bash check at its wall-clock budget and blocks (fails closed)
# with a message that names the fix, instead of running toward its registry
# timeout (feedback_d7a993c8: one call took 54 s of a 60 s timeout).
#
# Sections:
#   [1] a command too long to check within a 1 s test budget blocks (exit 2)
#       with the script-file message and returns soon after the budget
#   [2] the same command still blocks when it also reads a credential file
#   [3] a short command is unaffected by a lowered 3 s budget (allowed, exit 0)
#   [4] the budget variable cannot raise the budget above 20 s, and garbage
#       values fall back to the 20 s default (source check; with
#       CRED_GUARD_BUDGET_CAP_CHECK=1 also a behavior check that runs the hook
#       for about 20 s, so CI enables it in one lane only)
#   [5] the registry keeps the guard fail_closed for Bash and Read
#
# The long command is built so the hook's separate arithmetic check
# (bash-arith-subst-guard-lib.sh) accepts it at once: no quote, $, brace,
# glob, assignment or keyword it inspects. An earlier version used thousands
# of v<i>="$(...)" assignments; on Linux the arithmetic check refused those
# before the credential analysis started, so the budget code never ran there.
#
# Env: CRED_GUARD_HOOK_BASH (default bash) picks the shell that runs the hook.

set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/block-credential-file-read.sh"
REG="$ROOT/.claude/hooks/hook-registry.json"
HOOK_BASH="${CRED_GUARD_HOOK_BASH:-bash}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cred-guard-budget.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FH="$TMP/home"
PROJ="$TMP/proj"
mkdir -p "$FH" "$PROJ"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1" >&2; }

payload() { # <command-file>
  jq -nc --rawfile c "$1" --arg cwd "$PROJ" \
    '{session_id:"cred-guard-budget-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}'
}

# run_hook <budget> <command-file>: sets RC, ELAPSED (s) and $TMP/err.
run_hook() {
  local start end
  payload "$2" > "$TMP/payload.json"
  start=$(date +%s)
  RC=0
  HOME="$FH" HQ_CREDENTIAL_GUARD_BUDGET_SECONDS="$1" "$HOOK_BASH" "$HOOK" \
    < "$TMP/payload.json" > "$TMP/out" 2> "$TMP/err" || RC=$?
  end=$(date +%s)
  ELAPSED=$((end - start))
}

# Every simple command costs a parse in the credential analysis (about 9 ms
# each under macOS /bin/bash), and the home reference and -r keep the call off
# the fast path, so <count> commands run far past a 1 s budget on any runner.
long_cmd() { # <file> <count> [extra-tail]
  local i=0
  : > "$1"
  while [ $i -lt "$2" ]; do
    printf 'cat ./docs/file%d.md | grep -r token ~/project%d && ' "$i" "$i" >> "$1"
    i=$((i + 1))
  done
  printf 'ls ./docs%s\n' "${3:-}" >> "$1"
}

echo "[1] a long command blocks at the budget with the script-file message"
long_cmd "$TMP/long.txt" 3000
run_hook 1 "$TMP/long.txt"
if [ "$RC" = 2 ]; then ok "long command exits 2"; else bad "long command want 2 got $RC err=$(head -c 300 "$TMP/err" | tr '\n' ' ')"; fi
if grep -q 'within 1s' "$TMP/err" && grep -q 'script file' "$TMP/err"; then
  ok "message names the budget and the script-file fix"
else
  bad "message missing budget or script-file fix: $(head -c 300 "$TMP/err" | tr '\n' ' ')"
fi
if [ "$ELAPSED" -le 8 ]; then ok "returned ${ELAPSED}s after start (budget 1s)"; else bad "took ${ELAPSED}s with a 1s budget"; fi

echo "[2] a long command that also reads a credential file still blocks"
long_cmd "$TMP/long-cred.txt" 3000 ' && cat ~/.npmrc'
run_hook 1 "$TMP/long-cred.txt"
if [ "$RC" = 2 ]; then ok "long command with a credential read exits 2"; else bad "long credential command want 2 got $RC"; fi

echo "[3] a short command is not affected"
printf 'ls -la ./src && echo "$(date +%%Y)"\n' > "$TMP/short.txt"
# The budget here is 3 s, not 1 s. SECONDS counts whole wall-clock seconds, so
# it can read 1 a few milliseconds after the hook starts when the start falls
# just before a second boundary. With a 1 s budget this short command was
# blocked in about one run in six (measured at 0.2 s per run), which made the
# section fail at random. A 3 s budget always leaves at least 2 s.
run_hook 3 "$TMP/short.txt"
if [ "$RC" = 0 ]; then ok "short command allowed under a 3s budget"; else bad "short command want 0 got $RC err=$(head -c 300 "$TMP/err" | tr '\n' ' ')"; fi

echo "[4] the budget variable can lower the budget but never raise it"
if grep -q '^CG_BUDGET_MAX=20$' "$HOOK" \
  && grep -qF '[ "$CG_BUDGET" -le "$CG_BUDGET_MAX" ] || CG_BUDGET=$CG_BUDGET_MAX' "$HOOK" \
  && grep -qF "case \"\$CG_BUDGET\" in ''|*[!0-9]*|0) CG_BUDGET=\$CG_BUDGET_MAX ;; esac" "$HOOK"; then
  ok "budget is capped at 20s and invalid values fall back to 20s"
else
  bad "budget cap or fallback missing from the hook"
fi
if grep -q '^SECONDS=0$' "$HOOK"; then ok "SECONDS is reset at start"; else bad "SECONDS is not reset, an inherited value can move the start"; fi
if [ "${CRED_GUARD_BUDGET_CAP_CHECK:-0}" = 1 ]; then
  # 8,000 commands take well over 20 s under macOS /bin/bash, so the capped
  # budget is what stops the check.
  long_cmd "$TMP/cap.txt" 8000
  for value in 999 abc; do
    run_hook "$value" "$TMP/cap.txt"
    if [ "$RC" = 2 ] && grep -q 'within 20s' "$TMP/err"; then
      ok "budget value $value runs with the 20s budget and blocks (${ELAPSED}s)"
    else
      bad "budget value $value: want exit 2 within 20s, got $RC after ${ELAPSED}s: $(head -c 300 "$TMP/err" | tr '\n' ' ')"
    fi
  done
fi

echo "[5] the guard stays fail_closed in the registry"
for matcher in Bash Read; do
  fc=$(jq -r --arg m "$matcher" '[.. | objects | select(.matcher? == $m) | .hooks[]? | select(.id == "block-credential-file-read") | .fail_closed][0] // empty' "$REG")
  if [ "$fc" = true ]; then ok "$matcher registration is fail_closed"; else bad "$matcher registration is not fail_closed ($fc)"; fi
done
bt=$(jq -r '[.. | objects | select(.matcher? == "Bash") | .hooks[]? | select(.id == "block-credential-file-read") | .timeout][0] // empty' "$REG")
case "$bt" in
  ''|*[!0-9]*) bad "no Bash timeout for the guard" ;;
  *) if [ "$bt" -gt 20 ]; then ok "registry timeout ${bt}s is above the 20s inner budget"; else bad "registry timeout ${bt}s is not above the 20s inner budget"; fi ;;
esac

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS: credential-read-guard-time-budget ($pass)"
  exit 0
fi
echo "FAILURES: credential-read-guard-time-budget ($fail failed, $pass passed)" >&2
exit 1
