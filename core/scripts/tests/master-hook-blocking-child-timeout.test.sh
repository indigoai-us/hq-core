#!/usr/bin/env bash
# master-hook-blocking-child-timeout.test.sh
#
# HQ_MASTER_CHILD_TIMEOUT shortens folder hooks only on events whose hooks
# cannot block: PostToolUse, PostToolUseFailure, PostCompact, Notification,
# SessionEnd, SubagentStart and PermissionDenied. On every other event
# (PreToolUse, UserPromptSubmit, PreCompact, SessionStart, ...) a folder hook
# keeps HQ_MASTER_BLOCKING_CHILD_TIMEOUT (default 120 s), so a slow guard is
# not killed into a block and a slow SessionStart bind is not killed before it
# binds the session. Stop and SubagentStop keep their own Stop limits.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "missing $MASTER"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl required"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-blocking-child.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FIX="$TMP/root"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts/lib" "$FIX/core/hooks" \
  "$FIX/workspace/sessions/blocking-s1" "$FIX/home" "$TMP/bin"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIX/.claude/hooks/hook-gate.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIX/.claude/hooks/hook-timeout-probe.sh"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/hook-adapter-core.sh"
cp "$ROOT/core/scripts/lib/perl-child-locale.sh" "$FIX/core/scripts/lib/perl-child-locale.sh"
chmod +x "$FIX/.claude/hooks/master-hook.sh" "$FIX/.claude/hooks/hook-gate.sh"
jq -n '{hooks:{}}' > "$FIX/.claude/hooks/hook-registry.json"
printf 'session_id: blocking-s1\ncompany_slug: acme\n' > "$FIX/workspace/sessions/blocking-s1/meta.yaml"

LIMITS="$TMP/limits"
cat > "$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" != -k ] || shift 2
limit="$1"
shift
case " $* " in
  *"/companies/acme/hooks/"*)
    printf '%s\n' "$limit" >> "$HQ_TEST_LIMITS"
    if [ "${HQ_TEST_CHILD_SECONDS:-0}" -gt "$limit" ]; then
      cat >/dev/null
      exit 124
    fi
    ;;
esac
exec "$@"
STUB
chmod +x "$TMP/bin/timeout"

company_hook() { # <event> <name> <body>
  mkdir -p "$FIX/companies/acme/hooks/$1"
  rm -f "$FIX/companies/acme/hooks/$1"/*.sh
  printf '#!/usr/bin/env bash\ncat >/dev/null\n%s\n' "$3" > "$FIX/companies/acme/hooks/$1/$2"
  chmod +x "$FIX/companies/acme/hooks/$1/$2"
}

now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f", time() * 1000'; }

run_master_with_path() { # <PATH> <event> [env assignments...] -> sets RC ELAPSED_MS LIMIT
  local path="$1" event="$2" started ended payload
  shift 2
  payload="$(jq -nc --arg cwd "$FIX" --arg e "$event" \
    '{hook_event_name:$e,session_id:"blocking-s1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"gh pr merge 1"},tool_response:{},prompt:"merge it",source:"startup"}')"
  : > "$LIMITS"
  started="$(now_ms)"
  RC=0
  printf '%s' "$payload" \
    | env PATH="$path" HOME="$FIX/home" BASH_ENV=/dev/null HQ_ROOT="$FIX" HQ_HOOK_TIMEOUT_SENTRY=0 \
        HQ_HOOK_DEDUPE=0 HQ_FLAG_HQ_ANYWHERE_RUNTIME=false CLAUDE_PROJECT_DIR="$FIX" \
        HQ_TEST_LIMITS="$LIMITS" HQ_TEST_CHILD_SECONDS=3 "$@" \
        bash "$FIX/.claude/hooks/master-hook.sh" "$event" \
        >"$TMP/out" 2>"$TMP/err" || RC=$?
  ended="$(now_ms)"
  ELAPSED_MS=$((ended - started))
  LIMIT="$(tr '\n' ' ' < "$LIMITS" | sed 's/ $//')"
}

run_master() { # <event> [env assignments...]: company hooks run under the stub timeout
  run_master_with_path "$TMP/bin:$PATH" "$@"
}

expect_limit() { # <expected> <what>
  [ "$LIMIT" = "$1" ] || fail "$2: master-hook gave the company hook limit '${LIMIT}', expected '$1'; stderr=$(cat "$TMP/err")"
}

DENY='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"review gate: no review"}}'

company_hook PreToolUse 40-Bash--review-gate.sh "printf '%s\n' '$DENY'"
run_master PreToolUse HQ_MASTER_CHILD_TIMEOUT=2
expect_limit 120 "PreToolUse deny"
[ "$RC" -eq 0 ] || fail "PreToolUse deny verdict exited $RC; stderr=$(cat "$TMP/err")"
grep -q '"permissionDecision":"deny"' "$TMP/out" || fail "PreToolUse deny verdict lost: $(cat "$TMP/out")"
grep -q 'review gate: no review' "$TMP/out" || fail "PreToolUse deny reason lost: $(cat "$TMP/out")"
pass "a 3 s PreToolUse company hook under HQ_MASTER_CHILD_TIMEOUT=2 gets 120 s and keeps its deny"

company_hook PreToolUse 40-Bash--review-gate.sh "exit 0"
run_master PreToolUse HQ_MASTER_CHILD_TIMEOUT=2
expect_limit 120 "PreToolUse allow"
[ "$RC" -eq 0 ] || fail "PreToolUse allow exited $RC; stderr=$(cat "$TMP/err")"
[ ! -s "$TMP/out" ] || fail "PreToolUse allow printed a verdict: $(cat "$TMP/out")"
! grep -q 'Blocked by hook\|timed out\|did not finish' "$TMP/err" || fail "PreToolUse allow was cut or blocked: $(cat "$TMP/err")"
pass "a 3 s PreToolUse company hook under HQ_MASTER_CHILD_TIMEOUT=2 gets 120 s and allows"

company_hook UserPromptSubmit 10-slow.sh "echo prompt-hook-finished"
run_master UserPromptSubmit HQ_MASTER_CHILD_TIMEOUT=2
expect_limit 120 "UserPromptSubmit"
[ "$RC" -eq 0 ] || fail "UserPromptSubmit exited $RC; stderr=$(cat "$TMP/err")"
grep -q 'prompt-hook-finished' "$TMP/out" || fail "UserPromptSubmit hook was cut: $(cat "$TMP/out")"
pass "a 3 s UserPromptSubmit company hook under HQ_MASTER_CHILD_TIMEOUT=2 gets 120 s and finishes"

company_hook PostToolUse 10-slow.sh "echo post-hook-finished"
run_master PostToolUse HQ_MASTER_CHILD_TIMEOUT=2
expect_limit 2 "PostToolUse"
[ "$RC" -eq 124 ] || fail "PostToolUse timeout exited $RC; stderr=$(cat "$TMP/err")"
! grep -q 'post-hook-finished' "$TMP/out" || fail "PostToolUse hook ran past the 2 s limit"
pass "a 3 s PostToolUse company hook under HQ_MASTER_CHILD_TIMEOUT=2 gets 2 s and is cut"

company_hook PreToolUse 40-Bash--review-gate.sh "exit 0"
run_master PreToolUse HQ_MASTER_CHILD_TIMEOUT=2 HQ_MASTER_BLOCKING_CHILD_TIMEOUT=1
expect_limit 1 "PreToolUse with HQ_MASTER_BLOCKING_CHILD_TIMEOUT=1"
[ "$RC" -eq 124 ] || fail "HQ_MASTER_BLOCKING_CHILD_TIMEOUT=1 exited $RC; stderr=$(cat "$TMP/err")"
pass "HQ_MASTER_BLOCKING_CHILD_TIMEOUT sets the PreToolUse folder hook limit"

company_hook PermissionRequest 10-slow.sh "echo unknown-event-hook-finished"
run_master PermissionRequest HQ_MASTER_CHILD_TIMEOUT=1
expect_limit 120 "PermissionRequest"
[ "$RC" -eq 0 ] || fail "PermissionRequest exited $RC; stderr=$(cat "$TMP/err")"
grep -q 'unknown-event-hook-finished' "$TMP/out" || fail "PermissionRequest hook was cut: $(cat "$TMP/out")"
pass "a 3 s hook on an event master-hook does not list (PermissionRequest) keeps the long limit"

company_hook SessionStart 35-work-mesh-session-start.sh "echo session-hook-finished"
run_master SessionStart HQ_MASTER_CHILD_TIMEOUT=2
expect_limit 120 "SessionStart"
[ "$RC" -eq 0 ] || fail "SessionStart exited $RC; stderr=$(cat "$TMP/err")"
grep -q 'session-hook-finished' "$TMP/out" || fail "SessionStart hook was cut: $(cat "$TMP/out")"
pass "a 3 s SessionStart company hook under HQ_MASTER_CHILD_TIMEOUT=2 gets 120 s and finishes"

run_master SessionStart HQ_MASTER_CHILD_TIMEOUT=1 HQ_MASTER_BLOCKING_CHILD_TIMEOUT=8
expect_limit 8 "SessionStart with the fleet limits"
[ "$RC" -eq 0 ] || fail "SessionStart under the fleet limits exited $RC; stderr=$(cat "$TMP/err")"
grep -q 'session-hook-finished' "$TMP/out" || fail "SessionStart hook was cut under the fleet limits: $(cat "$TMP/out")"
pass "SessionStart company hooks get HQ_MASTER_BLOCKING_CHILD_TIMEOUT (8 s), not HQ_MASTER_CHILD_TIMEOUT"

run_master SessionStart HQ_MASTER_CHILD_TIMEOUT=30 HQ_MASTER_BLOCKING_CHILD_TIMEOUT=2
expect_limit 2 "SessionStart with HQ_MASTER_BLOCKING_CHILD_TIMEOUT=2"
[ "$RC" -eq 124 ] || fail "SessionStart under HQ_MASTER_BLOCKING_CHILD_TIMEOUT=2 exited $RC; stderr=$(cat "$TMP/err")"
! grep -q 'session-hook-finished' "$TMP/out" || fail "SessionStart hook ran past HQ_MASTER_BLOCKING_CHILD_TIMEOUT=2"
pass "HQ_MASTER_BLOCKING_CHILD_TIMEOUT cuts a 3 s SessionStart company hook at 2 s"

company_hook SessionEnd 10-slow.sh "echo session-end-finished"
run_master SessionEnd HQ_MASTER_CHILD_TIMEOUT=2 HQ_MASTER_BLOCKING_CHILD_TIMEOUT=30
expect_limit 2 "SessionEnd"
[ "$RC" -eq 124 ] || fail "SessionEnd timeout exited $RC; stderr=$(cat "$TMP/err")"
! grep -q 'session-end-finished' "$TMP/out" || fail "SessionEnd hook ran past the 2 s limit"
pass "a 3 s SessionEnd company hook under HQ_MASTER_CHILD_TIMEOUT=2 gets 2 s and is cut"

company_hook PreToolUse 40-Bash--review-gate.sh "echo parallel-guard-finished"
run_master PreToolUse HQ_HOOK_PARALLEL=1 HQ_MASTER_CHILD_TIMEOUT=1
expect_limit 120 "parallel PreToolUse"
[ "$RC" -eq 0 ] || fail "parallel PreToolUse exited $RC; stderr=$(cat "$TMP/err")"
grep -q 'parallel-guard-finished' "$TMP/out" || fail "parallel PreToolUse hook was cut: $(cat "$TMP/out")"
pass "HQ_HOOK_PARALLEL=1: a 3 s PreToolUse company hook keeps the long limit"

company_hook SessionStart 35-work-mesh-session-start.sh "echo parallel-session-finished"
run_master SessionStart HQ_HOOK_PARALLEL=1 HQ_MASTER_CHILD_TIMEOUT=1 HQ_MASTER_BLOCKING_CHILD_TIMEOUT=8
expect_limit 8 "parallel SessionStart"
[ "$RC" -eq 0 ] || fail "parallel SessionStart exited $RC; stderr=$(cat "$TMP/err")"
grep -q 'parallel-session-finished' "$TMP/out" || fail "parallel SessionStart hook was cut: $(cat "$TMP/out")"
pass "HQ_HOOK_PARALLEL=1: a 3 s SessionStart company hook gets HQ_MASTER_BLOCKING_CHILD_TIMEOUT"

company_hook PostToolUse 10-slow.sh "echo parallel-post-finished"
run_master PostToolUse HQ_HOOK_PARALLEL=1 HQ_MASTER_CHILD_TIMEOUT=1 HQ_MASTER_BLOCKING_CHILD_TIMEOUT=30
expect_limit 1 "parallel PostToolUse"
[ "$RC" -eq 124 ] || fail "parallel PostToolUse exited $RC; stderr=$(cat "$TMP/err")"
! grep -q 'parallel-post-finished' "$TMP/out" || fail "parallel PostToolUse hook ran past the 1 s limit"
pass "HQ_HOOK_PARALLEL=1: a 3 s PostToolUse company hook is cut at HQ_MASTER_CHILD_TIMEOUT=1"

company_hook SessionStart 35-work-mesh-session-start.sh "sleep 1.5
echo real-session-finished"
run_master_with_path "$PATH" SessionStart HQ_MASTER_CHILD_TIMEOUT=1
[ ! -s "$LIMITS" ] || fail "the real-runner case used the stub timeout"
[ "$RC" -eq 0 ] || fail "real-runner SessionStart exited $RC; stderr=$(cat "$TMP/err")"
grep -q 'real-session-finished' "$TMP/out" || fail "real-runner SessionStart hook was cut at HQ_MASTER_CHILD_TIMEOUT=1: $(cat "$TMP/out")"
[ "$ELAPSED_MS" -ge 1500 ] || fail "real-runner SessionStart hook did not run its 1.5 s: ${ELAPSED_MS}ms"
pass "real runner: a 1.5 s SessionStart company hook outlives HQ_MASTER_CHILD_TIMEOUT=1 (${ELAPSED_MS}ms)"

echo "PASS: master-hook-blocking-child-timeout"
