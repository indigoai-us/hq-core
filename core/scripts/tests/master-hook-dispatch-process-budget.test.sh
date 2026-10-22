#!/usr/bin/env bash
# hq-core: public
# master-hook-dispatch-process-budget.test.sh
#
# feedback_76ee6600 / feedback_22c2e203: hook dispatch cost ~5 s per tool call
# and ~15 s per prompt on Windows Git Bash, where every process start is
# 10-30x the macOS cost. Part of that was the dispatcher itself: two rm per
# child (completion markers), a shasum|awk pipeline for every hash (four of
# them hashed the same session id), cat for the registry cache, basename per
# directory hook, mkdir -p for directories that already existed, and a
# metadata rewrite (printf + mv) on every event.
#
# This test counts the PATH-resolved external processes master-hook starts for
# one benign PreToolUse event on a fixture with N no-op registry children, and
# asserts a budget that the pre-fix dispatcher exceeds. The count excludes
# nothing: timeout and bash for each child are part of the budget, so the
# bound is "fixed dispatcher cost + 2 per child" (timeout + bash, or perl).
#
# It also pins the per-session file prefilter ({session_id} placeholder and
# glob): hooks keyed on per-session state are skipped while that state is
# absent and run as soon as it exists (superset property).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

FIX="$TMP/root"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts/lib" "$FIX/core/policies" \
  "$FIX/personal/policies" "$FIX/workspace" "$FIX/home" "$TMP/bin"
for rel in \
  .claude/hooks/master-hook.sh \
  .claude/hooks/hook-gate.sh \
  .claude/hooks/hook-timeout-probe.sh \
  .claude/hooks/hook-timeout-watchdog.sh \
  core/scripts/lib/hook-adapter-core.sh \
  core/scripts/lib/trigger-fact-text.awk \
  core/scripts/resolve-hq-root.sh \
  core/scripts/lib/session-scope-capability.sh; do
  mkdir -p "$FIX/${rel%/*}"
  cp "$ROOT/$rel" "$FIX/$rel"
done
printf 'hqVersion: test\n' > "$FIX/core/core.yaml"

# PATH shims count every PATH-resolved exec when HQ_EXEC_LOG is set, then run
# the real tool. bash is included so the per-child `timeout N bash -c` start is
# counted; scripts run through their shebang are not on PATH and are not.
for name in jq perl awk sed grep cat date shasum sha256sum openssl mkdir mv rm cp timeout gtimeout basename dirname wc tail head cut sort tr uname getconf sysctl paste find git node ls setsid mktemp xargs cmp ps sleep touch env stat readlink bash sh uniq tee; do
  real="$(PATH="${PATH//$TMP\/bin:/}" command -v "$name" 2>/dev/null || true)"
  [ -n "$real" ] || continue
  printf '#!/bin/sh\n[ -z "${HQ_EXEC_LOG:-}" ] || printf %%s\\\\n %s >> "$HQ_EXEC_LOG"\nexec %s "$@"\n' "$name" "$real" > "$TMP/bin/$name"
  chmod +x "$TMP/bin/$name"
done

# N no-op children, every one of them an always-on exec runner (the shape of
# the always-on rows: block-hq-worktree-session, policy-enforcement-gate, ...).
N=8
children='[]'
for i in $(seq 1 "$N"); do
  printf '#!/bin/bash\nexit 0\n' > "$FIX/.claude/hooks/noop-$i.sh"
  chmod +x "$FIX/.claude/hooks/noop-$i.sh"
  children="$(jq -c --arg id "noop-$i" --arg s ".claude/hooks/noop-$i.sh" '. + [{id:$id,script:$s,timeout:30,gated:false}]' <<<"$children")"
done
# Three per-session prefiltered rows mirror the registry: a glob on a session
# directory, a per-session state file, and an unguarded control.
cat > "$FIX/.claude/hooks/pf-monitor.sh" <<'SH'
#!/bin/bash
printf 'pf-monitor ran\n' >&2
exit 0
SH
cat > "$FIX/.claude/hooks/pf-enforce.sh" <<'SH'
#!/bin/bash
printf 'pf-enforce ran\n' >&2
exit 0
SH
chmod +x "$FIX/.claude/hooks/pf-monitor.sh" "$FIX/.claude/hooks/pf-enforce.sh"
jq -n --argjson kids "$children" '{hooks:{PreToolUse:[{matcher:"",hooks:($kids + [
  {id:"pf-monitor",script:".claude/hooks/pf-monitor.sh",timeout:10,gated:false,prefilter:{file:"workspace/monitors/sessions/*-{session_id}"}},
  {id:"pf-enforce",script:".claude/hooks/pf-enforce.sh",timeout:10,gated:false,prefilter:{file:"workspace/orchestrator/policy-enforcement/{session_id}.*"}}
])}]}}' > "$FIX/.claude/hooks/hook-registry.json"

SID=budget-session-01
payload="$(jq -cn --arg s "$SID" --arg cwd "$FIX" '{session_id:$s,hook_event_name:"PreToolUse",tool_name:"Bash",tool_use_id:"tu1",cwd:$cwd,tool_input:{command:"git status"}}')"
run_master() { # [extra env...] -> ERR, RC, EXECS
  local log="$TMP/exec.log"
  : > "$log"
  ERR="$TMP/err"
  printf '%s' "$payload" | env "$@" PATH="$TMP/bin:$PATH" HOME="$FIX/home" HQ_ROOT="$FIX" \
    CLAUDE_PROJECT_DIR="$FIX" BASH_ENV=/dev/null HQ_HOOK_DEDUPE=0 HQ_ALLOW_HQ_WORKTREE=1 \
    HQ_EXEC_LOG="$log" HQ_HOOK_TRACE=1 \
    bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse >"$TMP/out" 2>"$ERR"
  RC=$?
  EXECS="$(wc -l < "$log" | tr -d ' ')"
  EXEC_SUMMARY="$(sort "$log" | uniq -c | sort -rn | awk '{printf "%s=%s ", $2, $1}')"
}

echo "[1] per-session file prefilters skip hooks whose state is absent"
run_master HQ_HOOK_TIMEOUT_SENTRY=0
[ "$RC" -eq 0 ] || fail "benign event exited $RC: $(cat "$ERR")"
grep -q 'skip pf-monitor (file)' "$ERR" && ! grep -q 'pf-monitor ran' "$ERR" \
  && pass "glob {session_id} prefilter skips the monitor hook" \
  || fail "monitor hook was not skipped: $(cat "$ERR")"
grep -q 'skip pf-enforce (file)' "$ERR" && ! grep -q 'pf-enforce ran' "$ERR" \
  && pass "{session_id}.* prefilter skips the enforcement hook" \
  || fail "enforcement hook was not skipped: $(cat "$ERR")"
runs="$(grep -c '^master-hook: run noop-' "$ERR" || true)"
[ "$runs" = "$N" ] && pass "all $N always-on children ran" || fail "expected $N child runs, saw $runs"

echo "[2] the same prefilters run the hook once the per-session state exists (superset)"
mkdir -p "$FIX/workspace/monitors/sessions/claude-$SID/active" "$FIX/workspace/orchestrator/policy-enforcement"
: > "$FIX/workspace/orchestrator/policy-enforcement/$SID.json"
run_master HQ_HOOK_TIMEOUT_SENTRY=0
grep -q 'pf-monitor ran' "$ERR" && pass "monitor hook runs when its session directory exists" \
  || fail "monitor hook did not run with state present: $(cat "$ERR")"
grep -q 'pf-enforce ran' "$ERR" && pass "enforcement hook runs when its session state exists" \
  || fail "enforcement hook did not run with state present: $(cat "$ERR")"
rm -rf "$FIX/workspace/monitors" "$FIX/workspace/orchestrator/policy-enforcement"

echo "[3] an unresolvable {session_id} placeholder runs the hook (fail toward running)"
. "$FIX/core/scripts/lib/hook-adapter-core.sh"
if hqad_registry_prefilter_match PreToolUse "$FIX" "" "$FIX" "" "git status" "" "" "workspace/orchestrator/policy-enforcement/{session_id}.*" "" pf-enforce; then
  pass "empty session id keeps a {session_id} file prefilter hook in the dispatch set"
else
  fail "empty session id skipped a {session_id} file prefilter hook"
fi
if hqad_registry_prefilter_match PreToolUse "$FIX" "" "$FIX" "../x" "git status" "" "" "workspace/orchestrator/policy-enforcement/{session_id}.*" "" pf-enforce; then
  pass "unsafe session id keeps a {session_id} file prefilter hook in the dispatch set"
else
  fail "unsafe session id skipped a {session_id} file prefilter hook"
fi
if hqad_registry_prefilter_match PreToolUse "$FIX" "" "$FIX" "$SID" "git status" "" "" "workspace/nothing-here/{session_id}" "" pf-x; then
  fail "resolvable placeholder with a missing path did not skip"
else
  [ "$HQAD_PREFILTER_REASON" = file ] && pass "resolvable placeholder with a missing path skips (reason=file)" \
    || fail "unexpected skip reason: $HQAD_PREFILTER_REASON"
fi

echo "[4] dispatcher process budget for one benign PreToolUse (watchdog on, long-session state present)"
# Warm the session: a second event sees existing session, journal, completion
# and registry-cache directories, like every event after the first in a session.
run_master HQ_HOOK_TIMEOUT_SENTRY=1
run_master HQ_HOOK_TIMEOUT_SENTRY=1
[ "$RC" -eq 0 ] || fail "warm event exited $RC: $(cat "$ERR")"
# Budget: per child one timeout runner plus one bash (perl alone when
# coreutils timeout is absent), plus the fixed dispatcher cost. The pre-fix
# dispatcher spent 2 rm per child, 2 processes per hash (x4-5), cat, mkdir x3,
# mv and basename on top: 56+ processes on this fixture. The fixed cost after
# the fix is: jq (payload), shasum x2 (invocation id, session id), awk x1
# (meta.yaml company read), mv/printf x0 (metadata unchanged), rm x2 (markers,
# debug files), setsid+bash x2 (watchdog), sleep x2 (watchdog), ls/awk x0.
per_child=2
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then per_child=2; else per_child=1; fi
fixed_budget=16
budget=$((fixed_budget + per_child * N))
printf '  execs=%s (budget %s): %s\n' "$EXECS" "$budget" "$EXEC_SUMMARY"
[ "$EXECS" -le "$budget" ] && pass "dispatcher started $EXECS processes for $N children (budget $budget)" \
  || fail "dispatcher started $EXECS processes for $N children; budget is $budget: $EXEC_SUMMARY"
rm_count="$(grep -c '^rm$' "$TMP/exec.log" || true)"
[ "$rm_count" -le 2 ] && pass "completion markers are removed in one rm (rm x$rm_count)" \
  || fail "rm ran $rm_count times; markers are not batched"
hash_count="$(grep -cE '^(shasum|sha256sum|openssl)$' "$TMP/exec.log" || true)"
[ "$hash_count" -le 2 ] && pass "session hash is computed once (hash processes x$hash_count)" \
  || fail "hash tool ran $hash_count times; session hash is not cached"

echo "[5] markers and journal state are cleaned up after the dispatch"
leftovers="$(find "$FIX/workspace/.hook-timeout-completions" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$leftovers" = "0" ] && pass "no completion markers left behind" || fail "$leftovers completion markers left behind"

if [ "$FAIL" -eq 0 ]; then echo "master-hook-dispatch-process-budget: all checks passed"; exit 0; fi
echo "master-hook-dispatch-process-budget: $FAIL failure(s)" >&2
exit 1
