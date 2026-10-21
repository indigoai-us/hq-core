#!/usr/bin/env bash
# hq-core: public
# master-hook-fail-closed-timeout.test.sh — a PreToolUse registry hook marked
# "fail_closed": true blocks the tool call when it times out or exits without
# a verdict, and a PostToolUse redaction survives a sibling's non-zero exit.
#
# Before this change a guard that ran past its registry timeout (exit 124/142,
# seen on Bash commands with 100+ operands) was treated as "no verdict" and the
# tool call ran. Hooks without the flag keep that behaviour.
#
# Sections:
#   [1] fail_closed hook that times out blocks (rc=2), all three profiles
#   [2] fail_closed hook that crashes (exit 1) blocks (rc=2)
#   [3] fail_closed hook that allows (exit 0) still allows
#   [4] hook without the flag keeps the old fail-open behaviour on timeout
#   [5] the shipped registry marks block-credential-file-read fail_closed for Read and Bash
#   [6] PostToolUse: updatedToolOutput survives a sibling exit 1 and exit 2
#   [7] a missing fail_closed guard script blocks; a missing unflagged one is skipped
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-fail-closed.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts/lib" "$FIX/workspace/orchestrator"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
for f in hook-timeout-probe.sh hook-timeout-watchdog.sh hook-gate.sh; do
  cp "$ROOT/.claude/hooks/$f" "$FIX/.claude/hooks/"
done
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$ROOT/core/scripts/lib/trigger-fact-text.awk" "$FIX/core/scripts/lib/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$FIX/core/scripts/"
printf 'hqVersion: "15.0.131"\n' > "$FIX/core/core.yaml"

# Fixture hooks. "slow" sleeps past its 1 s registry timeout.
mk() { printf '#!/usr/bin/env bash\ncat >/dev/null\n%s\n' "$2" > "$FIX/.claude/hooks/$1.sh"; chmod +x "$FIX/.claude/hooks/$1.sh"; }
mk slow 'sleep 5; exit 0'
mk crash 'exit 1'
mk allow 'exit 0'
mk redact 'printf "%s\n" "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"updatedToolOutput\":{\"stdout\":\"_authToken=[REDACTED]\",\"stderr\":\"\"}}}"; exit 0'
mk sib1 'echo "sibling exit 1" >&2; exit 1'
mk sib2 'echo "sibling block" >&2; exit 2'

# registry ID SCRIPT FAIL_CLOSED [EVENT] [SECOND_SCRIPT]
registry() {
  local id="$1" script="$2" fc="$3" ev="${4:-PreToolUse}" second="${5:-}"
  jq -nc --arg id "$id" --arg s ".claude/hooks/$script.sh" --argjson fc "$fc" --arg ev "$ev" --arg s2 "$second" '
    {hooks: {($ev): [{matcher: "Bash|Read", hooks: (
      [{id: $id, script: $s, timeout: 1, gated: true, fail_closed: $fc, runner: "exec"}]
      + (if $s2 == "" then [] else [{id: "fixture-sibling", script: (".claude/hooks/" + $s2 + ".sh"), timeout: 5, gated: false, runner: "exec"}] end)
    )}]}}' > "$FIX/.claude/hooks/hook-registry.json"
  rm -rf "$FIX/workspace/orchestrator/hook-state/registry-rows"
}

# run EVENT PROFILE TOOL -> sets RC; stdout in $TMP/out, stderr in $TMP/err
run() {
  local pl
  if [ "$3" = "Read" ]; then
    pl="$(jq -nc --arg d "$FIX" --arg e "$1" '{session_id:"fc-test",hook_event_name:$e,tool_name:"Read",cwd:$d,tool_input:{file_path:($d + "/README.md")},tool_response:{type:"text",file:{content:"x"}}}')"
  else
    pl="$(jq -nc --arg d "$FIX" --arg e "$1" '{session_id:"fc-test",hook_event_name:$e,tool_name:"Bash",cwd:$d,tool_input:{command:"echo hi"},tool_response:{stdout:"x",stderr:""}}')"
  fi
  RC=0
  printf '%s' "$pl" | (cd "$FIX" && env HQ_HOOK_PROFILE="$2" CLAUDE_PROJECT_DIR="$FIX" HQ_ROOT="$FIX" \
    HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=0 bash "$FIX/.claude/hooks/master-hook.sh" "$1") \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
}

echo "[1] fail_closed timeout blocks"
registry block-credential-file-read slow true
for p in minimal standard strict; do
  for t in Bash Read; do
    run PreToolUse "$p" "$t"
    if [ "$RC" = "2" ] && grep -q 'block-credential-file-read timed out' "$TMP/err"; then
      ok "profile=$p $t timeout -> rc 2"
    else
      bad "profile=$p $t timeout want rc 2 got $RC err=$(head -c 300 "$TMP/err" | tr '\n' ' ')"
    fi
  done
done

echo "[2] fail_closed crash blocks"
registry block-credential-file-read crash true
run PreToolUse standard Bash
[ "$RC" = "2" ] && grep -q 'exited 1 without a verdict' "$TMP/err" \
  && ok "crash exit 1 -> rc 2" || bad "crash want rc 2 got $RC err=$(head -c 300 "$TMP/err" | tr '\n' ' ')"

echo "[3] fail_closed allow still allows"
registry block-credential-file-read allow true
run PreToolUse standard Bash
[ "$RC" = "0" ] && ok "allow exit 0 -> rc 0" || bad "allow want rc 0 got $RC"

echo "[4] unflagged hook keeps fail-open behaviour"
registry block-credential-file-read slow false
run PreToolUse standard Bash
[ "$RC" != "2" ] && ! grep -q 'failing closed' "$TMP/err" \
  && ok "unflagged timeout does not block (rc=$RC)" || bad "unflagged timeout blocked (rc=$RC)"
# The flag only applies to PreToolUse.
registry block-credential-file-read slow true PostToolUse
run PostToolUse standard Bash
[ "$RC" != "2" ] && ok "fail_closed ignored on PostToolUse (rc=$RC)" || bad "PostToolUse timeout blocked"

echo "[5] shipped registry"
for m in Read Bash; do
  v="$(jq -r --arg m "$m" '[.hooks.PreToolUse[] | select(.matcher == $m) | .hooks[] | select(.id == "block-credential-file-read") | .fail_closed] | first // "missing"' "$ROOT/.claude/hooks/hook-registry.json")"
  [ "$v" = "true" ] && ok "PreToolUse $m guard fail_closed=true" || bad "PreToolUse $m guard fail_closed=$v"
  v="$(jq -r --arg m "$m" '[.hooks.PostToolUse[] | select(.matcher == $m) | .hooks[] | select(.id == "redact-credential-output")] | length' "$ROOT/.claude/hooks/hook-registry.json")"
  [ "$v" = "1" ] && ok "PostToolUse $m redactor registered" || bad "PostToolUse $m redactor count=$v"
done

echo "[6] PostToolUse redaction survives sibling exits"
registry redact-credential-output redact false PostToolUse sib1
run PostToolUse standard Bash
if [ "$RC" = "0" ] && [ "$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout' "$TMP/out" 2>/dev/null)" = "_authToken=[REDACTED]" ]; then
  ok "sibling exit 1: rc 0 and updatedToolOutput kept"
else
  bad "sibling exit 1: rc=$RC out=$(head -c 300 "$TMP/out")"
fi
registry redact-credential-output redact false PostToolUse sib2
run PostToolUse standard Bash
if [ "$RC" = "0" ] && [ "$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout' "$TMP/out" 2>/dev/null)" = "_authToken=[REDACTED]" ] \
  && [ "$(jq -r '.decision' "$TMP/out" 2>/dev/null)" = "block" ] \
  && jq -r '.reason' "$TMP/out" 2>/dev/null | grep -qF 'sib2.sh'; then
  ok "sibling exit 2: rc 0, updatedToolOutput kept, decision block naming the sibling"
else
  bad "sibling exit 2: rc=$RC out=$(head -c 300 "$TMP/out")"
fi

echo "[7] missing guard script"
registry block-credential-file-read gone-guard true
for p in minimal standard strict; do
  for t in Bash Read; do
    run PreToolUse "$p" "$t"
    if [ "$RC" = "2" ] && grep -q 'block-credential-file-read guard script .* is missing; failing closed' "$TMP/err" \
      && grep -qF 'checkout -- ".claude/hooks/gone-guard.sh"' "$TMP/err"; then
      ok "profile=$p $t missing fail_closed script -> rc 2 with the restore command"
    else
      bad "profile=$p $t missing script want rc 2 got $RC err=$(head -c 300 "$TMP/err" | tr '\n' ' ')"
    fi
  done
done
registry block-credential-file-read gone-guard false
run PreToolUse standard Bash
[ "$RC" = "0" ] && ok "missing unflagged script is skipped (rc 0)" || bad "missing unflagged script rc=$RC"
registry block-credential-file-read gone-guard true PostToolUse
run PostToolUse standard Bash
[ "$RC" = "0" ] && ok "missing fail_closed script ignored on PostToolUse" || bad "PostToolUse missing script rc=$RC"

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS: master-hook-fail-closed-timeout ($pass)"
  exit 0
fi
echo "FAILURES: master-hook-fail-closed-timeout ($fail failed, $pass passed)" >&2
exit 1
