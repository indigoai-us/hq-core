#!/usr/bin/env bash
# hq-core: public
# Regression: the mandatory scope authorizer must not time out silently on a
# long inline Bash command (feedback family 746662e0). Before the fix, checking
# a command grew faster than its length (quadratic work over repeated words,
# plus bash 3.2's slow ${var//[class]/} on the whole text), so 25 short lines
# took over a minute and the host killed the hook at its 25 s cap.
#
# Asserted here, with time bounds generous enough for a loaded CI runner:
#   - a long heredoc of data is allowed fast
#   - a many-line command is allowed, and a cross-company read hidden at the end
#     of one is still denied with the same message
#   - a command too long to check fails closed with a message that names the
#     fix (a script file), well before the host timeout
#   - the helpers rewritten for speed return what the old per-character code did
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
DEFAULT_ROOT=$(git -C "$TEST_DIR/../../.." rev-parse --show-toplevel)
ROOT=${HOOK_ROOT_OVERRIDE:-$DEFAULT_ROOT}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)
FIXTURE=$TMP/hq-root
mkdir -p "$FIXTURE/.claude/hooks" "$FIXTURE/core/scripts/lib" "$FIXTURE/companies/indigo/settings" \
  "$FIXTURE/companies/otherco/settings" "$FIXTURE/companies/_template" "$FIXTURE/personal" \
  "$FIXTURE/workspace/sessions/sess-bound"
for path in .claude/hooks/bash-arith-subst-guard-lib.sh .claude/hooks/mandatory-scope-authorizer.sh \
  core/scripts/lib/session-authz.sh core/scripts/lib/session-scope-capability.sh \
  core/scripts/lib/session-id.sh core/scripts/hook-lib.sh core/scripts/lib/hook-caller-lineage.sh \
  core/scripts/hqd-hook-flag-cache-lib.sh; do
  if [ -f "$ROOT/$path" ]; then
    mkdir -p "$FIXTURE/$(dirname "$path")"
    cp "$ROOT/$path" "$FIXTURE/$path"
  fi
done
printf 'companies:\n  indigo:\n  otherco:\n' > "$FIXTURE/companies/manifest.yaml"
touch "$FIXTURE/companies/indigo/settings/.keep" "$FIXTURE/companies/otherco/settings/.keep"
printf '{"session_id":"sess-bound","company_slug":"indigo"}\n' \
  > "$FIXTURE/workspace/sessions/sess-bound/scope-capability.json"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

# run_hook <label> <command> [env assignments...]; sets RC, ELAPSED, ERR_FILE.
run_hook() {
  local label=$1 command=$2 payload start
  shift 2
  payload=$(jq -cn --arg cwd "$FIXTURE" --arg command "$command" \
    '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')
  ERR_FILE=$TMP/$label.err
  RC=0
  start=$SECONDS
  printf '%s' "$payload" | env HQ_HOOK_TOOL_NAME=Bash HQ_HOOK_SESSION_ID=sess-bound \
    HQ_HOOK_CWD="$FIXTURE" HQ_HOOK_AGENT_ID="" HQ_HOOK_AGENT_TYPE="" \
    CLAUDE_PROJECT_DIR="$FIXTURE" "$@" \
    bash "$FIXTURE/.claude/hooks/mandatory-scope-authorizer.sh" > "$TMP/$label.out" 2> "$ERR_FILE" || RC=$?
  ELAPSED=$((SECONDS - start))
}

many_lines() {
  local n=$1 i
  for ((i = 0; i < n; i++)); do
    printf "echo step %d | grep -v foo | sed 's/a/b/' > /tmp/out%d.txt && ls -la /tmp/x%d || true\n" "$i" "$i" "$i"
  done
}

# 1. 300-line heredoc of data: allowed, fast.
heredoc="cat > /tmp/long-note.md <<'EOT'"$'\n'
for ((i = 0; i < 300; i++)); do
  heredoc+="line $i some text with \$dollar and path /usr/bin/x$i words words"$'\n'
done
heredoc+="EOT"
run_hook heredoc "$heredoc"
if [ "$RC" = 0 ] && [ "$ELAPSED" -le 20 ]; then ok "300-line data heredoc allowed in ${ELAPSED}s"; else bad "heredoc rc=$RC elapsed=${ELAPSED}s"; fi

# 2. Six-line command: allowed. The old code needed several seconds here on a quiet
# machine and grew quadratically; the bound leaves room for a loaded runner.
run_hook six "$(many_lines 6)"
if [ "$RC" = 0 ] && [ "$ELAPSED" -le 30 ]; then ok "6-line command allowed in ${ELAPSED}s"; else bad "6-line rc=$RC elapsed=${ELAPSED}s"; fi

# 3. Same six lines plus a cross-company read: still denied, same message.
run_hook six-deny "$(many_lines 6)"$'\n'"cat companies/otherco/settings/secret.yaml"
if [ "$RC" = 2 ] && grep -q 'Cross-company scope violation' "$ERR_FILE" && grep -q 'companies/otherco/settings/secret.yaml' "$ERR_FILE"; then
  ok "cross-company read after 6 lines still denied"
else
  bad "6-line deny rc=$RC: $(head -c 300 "$ERR_FILE")"
fi

# 4. Too long to check: fails closed, quickly, telling the user to use a script.
run_hook oversize "$(many_lines 400)"
if [ "$RC" = 2 ] && grep -qi 'script file' "$ERR_FILE" && [ "$ELAPSED" -le 20 ]; then
  ok "400-line command fails closed with a script-file message in ${ELAPSED}s"
else
  bad "400-line rc=$RC elapsed=${ELAPSED}s: $(head -c 300 "$ERR_FILE")"
fi

# 5. The wall-clock budget turns a slow check into the same message, not a timeout.
run_hook budget "$(many_lines 40)" HQ_SCOPE_CHECK_BUDGET_SECS=1
if [ "$RC" = 2 ] && grep -q 'too long for the scope guard' "$ERR_FILE" && [ "$ELAPSED" -le 25 ]; then
  ok "budget exceeded blocks with an explanation in ${ELAPSED}s"
else
  bad "budget rc=$RC elapsed=${ELAPSED}s: $(head -c 300 "$ERR_FILE")"
fi

# 5b. Malformed limits must not switch the gate or budget off. 150 lines is over
# the size gate but under the arithmetic guard's 16 KiB cap, so only the gate
# can reject it; its message names the character count, which the budget
# message does not. Huge, negative, empty and non-numeric values all fall back to
# the defaults and still fail closed with the script-file message.
long150=$(many_lines 150)
for bad_value in 99999999999999999999999 -5 "" abc 1.5 "0x10" "12 34"; do
  run_hook "gate-bad" "$long150" "HQ_SCOPE_MAX_SCAN_CHARS=$bad_value"
  if [ "$RC" = 2 ] && grep -q 'characters long; the limit is' "$ERR_FILE" && [ "$ELAPSED" -le 25 ]; then
    ok "size gate stays active with HQ_SCOPE_MAX_SCAN_CHARS='$bad_value'"
  else
    bad "gate with MAX_SCAN_CHARS='$bad_value' rc=$RC elapsed=${ELAPSED}s: $(head -c 200 "$ERR_FILE")"
  fi
  run_hook "budget-bad" "$long150" "HQ_SCOPE_CHECK_BUDGET_SECS=$bad_value" HQ_SCOPE_MAX_SCAN_CHARS=1000
  if [ "$RC" = 2 ] && grep -q 'characters long; the limit is' "$ERR_FILE" && [ "$ELAPSED" -le 25 ]; then
    ok "budget stays bounded with HQ_SCOPE_CHECK_BUDGET_SECS='$bad_value'"
  else
    bad "budget with CHECK_BUDGET_SECS='$bad_value' rc=$RC elapsed=${ELAPSED}s: $(head -c 200 "$ERR_FILE")"
  fi
done

# 5c. The repeated-word memo never lets a denied word through: the same
# clean word repeated, then a denied word repeated, is still blocked.
run_hook memo-deny "ls /tmp/x1; ls /tmp/x1; ls /tmp/x1; cat companies/otherco/settings/secret.yaml; cat companies/otherco/settings/secret.yaml"
if [ "$RC" = 2 ] && grep -q 'Cross-company scope violation' "$ERR_FILE"; then ok "repeated denied word still blocked"; else bad "memo-deny rc=$RC: $(head -c 200 "$ERR_FILE")"; fi
run_hook memo-allow "ls /tmp/x1; ls /tmp/x1; ls /tmp/x1"
if [ "$RC" = 0 ]; then ok "repeated clean word allowed"; else bad "memo-allow rc=$RC: $(head -c 200 "$ERR_FILE")"; fi

# 6. Speed-rewritten helpers return what the per-character code returned.
eval "$(sed -n '/^scope_mask_literal_expansions() {/,/^}/p' "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh")"
eval "$(sed -n '/^scope_candidate_is_single_quoted() {/,/^}/p' "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh")"
eval "$(sed -n '/^scope_drop_quote_chars() {/,/^}/p' "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh")"
M=__HQ_LITERAL_EXPANSION__
check_mask() {
  local input=$1 expected=$2 actual
  actual=$(scope_mask_literal_expansions "$input")
  if [ "$actual" = "$expected" ]; then ok "mask: $input"; else bad "mask: $input => $actual (want $expected)"; fi
}
check_mask 'cat companies/$co/x' 'cat companies/$co/x'
check_mask "echo 'a\$b *' \$x" "echo 'a${M}b ${M}' \$x"
check_mask 'grep -E "done$|x"' 'grep -E "done'"$M"'|x"'
check_mask 'a\$b \* c' "a\\${M}b \\${M} c"
check_mask 'trailing\' 'trailing\'
check_mask 'end$' "end$M"
check_sq() {
  local candidate=$1 prefix=$2 want=$3 got=0
  scope_candidate_is_single_quoted "$candidate" "$prefix" || got=$?
  if [ "$got" = "$want" ]; then ok "single-quoted: [$prefix]"; else bad "single-quoted: [$prefix] got $got want $want"; fi
}
check_sq x "echo '" 0
check_sq x "echo 'a' " 1
check_sq x 'echo "it'"'"'s ' 1
check_sq x "echo \"a\" 'b" 0
check_sq "" "echo '" 1
big=$(printf "x'%.0s" $(seq 1 600))"y\"z"
scope_drop_quote_chars "$big" bs
if [ "$SCOPE_DROPPED" = "${big//[\"\'\\]/}" ]; then ok "drop quote chars, long text"; else bad "drop quote chars, long text"; fi

if (( FAIL > 0 )); then
  printf 'mandatory-scope-authorizer-long-command: %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf 'mandatory-scope-authorizer-long-command: %s passed, %s failed\n' "$PASS" "$FAIL"
