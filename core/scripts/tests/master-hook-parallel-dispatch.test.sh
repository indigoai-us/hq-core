#!/usr/bin/env bash
# master-hook-parallel-dispatch.test.sh
#
# Pins the HQ_HOOK_PARALLEL=1 dispatch path in master-hook.sh:
#   - merged stdout, stderr and exit code match the sequential run, for
#     allow, context and block cases, on PreToolUse, UserPromptSubmit and Stop
#   - every block still blocks, including two guards that block at once
#   - a guard whose background job died without a result file blocks
#   - registry "after" ordering, directory_hook_after ordering, the
#     registry-before-directory barrier and same-name ordering are honoured
#   - the shared safety-guard budget is enforced for guards held back by the
#     concurrency cap
#   - each running child has its own timeout breadcrumb file
#   - flag off (unset or 0) and bash older than 5.1 stay sequential
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "missing $MASTER"
command -v jq >/dev/null 2>&1 || fail "jq is required"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-parallel.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BASH_BIN="${MASTER_HOOK_PARALLEL_BASH:-$(command -v bash)}"
bash_ok="$("$BASH_BIN" -c '[ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; } && echo 1 || echo 0')"
[ "$bash_ok" = 1 ] || fail "$BASH_BIN is older than bash 5.1; set MASTER_HOOK_PARALLEL_BASH to a bash 5.1+ binary"

FIX="$TMP/root"
H="$FIX/.claude/hooks"
mkdir -p "$H" "$FIX/core/scripts/lib" "$FIX/core/hooks/Stop" "$FIX/personal/hooks/Stop" \
  "$FIX/core/hooks/UserPromptSubmit" "$FIX/workspace" "$TMP/state"
cp "$MASTER" "$H/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$H/hook-gate.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$H/hook-timeout-probe.sh"
cp "$ROOT/.claude/hooks/hook-timeout-watchdog.sh" "$H/hook-timeout-watchdog.sh"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/hook-adapter-core.sh"
[ ! -f "$ROOT/core/scripts/resolve-hq-root.sh" ] || cp "$ROOT/core/scripts/resolve-hq-root.sh" "$FIX/core/scripts/resolve-hq-root.sh"
chmod +x "$H/master-hook.sh" "$H/hook-gate.sh"

ST="$TMP/state"
# stub <path> <body>: an executable hook that drains stdin first.
stub() {
  printf '#!/usr/bin/env bash\ncat >/dev/null\n%s\n' "$2" > "$1"
  chmod +x "$1"
}
now_ms='m(){ local r="${EPOCHREALTIME/./}"; printf "%s" "${r:0:13}"; }'

# PreToolUse registry hooks.
stub "$H/ctx-a.sh" 'sleep 0.3; printf "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"ctx-a\"}}\n"'
stub "$H/ctx-b.sh" 'sleep 0.1; echo "plain from ctx-b"; echo "ctx-b stderr" >&2'
stub "$H/order-first.sh" "$now_ms"'
s="$(m)"; sleep 0.4; : > "'"$ST"'/first.stamp"; printf "%s %s\n" "$s" "$(m)" > "'"$ST"'/first.times"'
stub "$H/order-second.sh" "$now_ms"'
s="$(m)"; if [ -f "'"$ST"'/first.stamp" ]; then echo "second saw stamp"; else echo "second raced"; fi
printf "%s %s\n" "$s" "$(m)" > "'"$ST"'/second.times"'
stub "$H/deny-a.sh" 'if [ -f "'"$ST"'/deny-a.on" ]; then sleep 0.2; echo "deny-a blocked" >&2; exit 2; fi'
stub "$H/deny-b.sh" 'if [ -f "'"$ST"'/deny-b.on" ]; then echo "deny-b blocked" >&2; exit 2; fi'
# Kills its own background dispatch job, so master-hook finds no result file.
# The launcher records the master-hook pid; the guard walks up its ancestors
# and kills the one whose parent is master-hook (its dispatch job).
stub "$H/vanish-guard.sh" '[ -f "'"$ST"'/vanish.on" ] || exit 0
master="$(cat "'"$ST"'/master.pid")"
pid=$$
while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
  parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d " ")"
  if [ "$parent" = "$master" ]; then kill -KILL "$pid"; break; fi
  pid="$parent"
done
sleep 1
exit 0'
stub "$H/slow-safety-1.sh" '[ -f "'"$ST"'/budget.on" ] || exit 0; sleep 4'
stub "$H/slow-safety-2.sh" '[ -f "'"$ST"'/budget.on" ] || exit 0; sleep 4'
# Directory hooks: the barrier and same-name ordering.
stub "$FIX/core/hooks/Stop/50-note.sh" "$now_ms"'
f="'"$ST"'/note.seen"; if [ -f "$f" ]; then echo "note again"; else : > "$f"; echo "note first"; fi
printf "%s %s\n" "$(m)" core >> "'"$ST"'/note.times"; sleep 0.2'
cp "$FIX/core/hooks/Stop/50-note.sh" "$FIX/personal/hooks/Stop/50-note.sh"
stub "$FIX/core/hooks/Stop/60-after-reg.sh" 'if [ -f "'"$ST"'/stop-reg.stamp" ]; then echo "dir saw registry"; else echo "dir raced registry"; fi'
stub "$FIX/core/hooks/Stop/40-dir-first.sh" 'sleep 0.3; : > "'"$ST"'/dirfirst.stamp"'
stub "$FIX/core/hooks/Stop/45-dir-second.sh" 'if [ -f "'"$ST"'/dirfirst.stamp" ]; then echo "dir order kept"; else echo "dir order raced"; fi'
stub "$H/stop-reg.sh" 'sleep 0.3; : > "'"$ST"'/stop-reg.stamp"; echo "stop registry ran"'
stub "$H/ups-ctx.sh" 'sleep 0.2; echo "ups context"'
stub "$FIX/core/hooks/UserPromptSubmit/30-ups-dir.sh" 'echo "ups dir hook"'

cat > "$H/hook-registry.json" <<JSON
{
  "\$schema": "hq-hook-registry@1",
  "description": "fixture",
  "directory_hook_after": {"Stop": {"45-dir-second.sh": ["40-dir-first.sh"]}},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [
        {"id": "ctx-a", "script": ".claude/hooks/ctx-a.sh", "gated": false},
        {"id": "order-first", "script": ".claude/hooks/order-first.sh", "gated": false},
        {"id": "ctx-b", "script": ".claude/hooks/ctx-b.sh", "gated": false},
        {"id": "order-second", "script": ".claude/hooks/order-second.sh", "gated": false, "after": ["order-first"]},
        {"id": "deny-a", "script": ".claude/hooks/deny-a.sh", "gated": false, "safety": true},
        {"id": "vanish-guard", "script": ".claude/hooks/vanish-guard.sh", "gated": false, "fail_closed": true},
        {"id": "deny-b", "script": ".claude/hooks/deny-b.sh", "gated": false, "fail_closed": true},
        {"id": "slow-safety-1", "script": ".claude/hooks/slow-safety-1.sh", "gated": false, "safety": true},
        {"id": "slow-safety-2", "script": ".claude/hooks/slow-safety-2.sh", "gated": false, "safety": true},
        {"id": "gone-guard", "script": ".claude/hooks/gone-guard.sh", "gated": false, "fail_closed": true,
         "prefilter": {"file": "workspace/gone-guard.on"}}
      ]}
    ],
    "UserPromptSubmit": [
      {"matcher": "", "hooks": [{"id": "ups-ctx", "script": ".claude/hooks/ups-ctx.sh", "gated": false}]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [{"id": "stop-reg", "script": ".claude/hooks/stop-reg.sh", "gated": false}]}
    ]
  }
}
JSON

# Records the master-hook pid for vanish-guard, then becomes master-hook.
printf '#!/usr/bin/env bash\nprintf "%%s" "$$" > "%s/master.pid"\nexec "%s" "%s/master-hook.sh" "$@"\n' \
  "$ST" "$BASH_BIN" "$H" > "$TMP/launch.sh"
chmod +x "$TMP/launch.sh"

payload() { # <event>
  case "$1" in
    PreToolUse) printf '{"session_id":"par-test","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"cwd":"%s"}' "$FIX" ;;
    UserPromptSubmit) printf '{"session_id":"par-test","hook_event_name":"UserPromptSubmit","prompt":"hello","cwd":"%s"}' "$FIX" ;;
    Stop) printf '{"session_id":"par-test","hook_event_name":"Stop","stop_hook_active":false,"cwd":"%s"}' "$FIX" ;;
  esac
}

reset_state() {
  rm -rf "$ST" "$FIX/workspace/orchestrator/hook-state/registry-rows"
  mkdir -p "$ST"
}

# run <mode: seq|par|zero> <event> <label> [env...]: writes $TMP/<label>.{out,err,rc,ms}
run() {
  local mode="$1" ev="$2" label="$3" rc=0 s e
  shift 3
  local envs=(env -i "HOME=$TMP" "PATH=$PATH" "TMPDIR=$TMP" "HQ_ROOT=$FIX" "CLAUDE_PROJECT_DIR=$FIX"
    "BASH_ENV=/dev/null" "HQ_HOOK_TIMEOUT_SENTRY=0" "HQ_SAFETY_GUARD_TIMEOUT=10")
  case "$mode" in
    par) envs+=("HQ_HOOK_PARALLEL=1") ;;
    zero) envs+=("HQ_HOOK_PARALLEL=0") ;;
  esac
  s="$(date +%s)"
  payload "$ev" | "${envs[@]}" "$@" "$BASH_BIN" "$TMP/launch.sh" "$ev" >"$TMP/$label.out" 2>"$TMP/$label.err" || rc=$?
  e="$(date +%s)"
  printf '%s' "$rc" > "$TMP/$label.rc"
  printf '%s' "$((e - s))" > "$TMP/$label.sec"
}

same() { # <label-a> <label-b> <what>
  cmp -s "$TMP/$1.out" "$TMP/$2.out" || { diff "$TMP/$1.out" "$TMP/$2.out" >&2 || true; fail "$3: stdout differs"; }
  cmp -s "$TMP/$1.err" "$TMP/$2.err" || { diff "$TMP/$1.err" "$TMP/$2.err" >&2 || true; fail "$3: stderr differs"; }
  cmp -s "$TMP/$1.rc" "$TMP/$2.rc" || fail "$3: exit code $(cat "$TMP/$1.rc") vs $(cat "$TMP/$2.rc")"
}

# 1. Allow and context output, every event: sequential, flag 0 and parallel agree.
for ev in PreToolUse UserPromptSubmit Stop; do
  reset_state; run seq "$ev" "$ev-seq"
  reset_state; run zero "$ev" "$ev-zero"
  reset_state; run par "$ev" "$ev-par"
  same "$ev-seq" "$ev-zero" "$ev flag 0"
  same "$ev-seq" "$ev-par" "$ev parallel"
  [ "$(cat "$TMP/$ev-par.rc")" = 0 ] || fail "$ev parallel exit $(cat "$TMP/$ev-par.rc")"
done
grep -q 'ctx-a' "$TMP/PreToolUse-par.out" || fail "PreToolUse context missing"
grep -q 'plain from ctx-b' "$TMP/PreToolUse-par.out" || fail "PreToolUse plain output missing"
grep -q 'ctx-b stderr' "$TMP/PreToolUse-par.err" || fail "child stderr was not replayed"
pass "allow and context output identical in sequential, flag 0 and parallel runs (PreToolUse, UserPromptSubmit, Stop)"

# 2. Ordering.
reset_state; run par PreToolUse ord
grep -q 'second saw stamp' "$TMP/ord.out" || fail "after: order-second ran before order-first finished"
read -r _ first_end < "$ST/first.times"
read -r second_start _ < "$ST/second.times"
[ "$second_start" -ge "$first_end" ] || fail "order-second started at $second_start before order-first ended at $first_end"
pass "registry after: order-second starts after order-first ends"
reset_state; run par Stop stop-ord
grep -q 'dir saw registry' "$TMP/stop-ord.out" || fail "a directory hook ran before the registry hooks finished"
grep -q 'dir order kept' "$TMP/stop-ord.out" || fail "directory_hook_after was not honoured"
grep -q 'note first' "$TMP/stop-ord.out" && grep -q 'note again' "$TMP/stop-ord.out" || fail "same-name hooks raced"
[ "$(grep -n 'note' "$TMP/stop-ord.out" | head -1 | cut -d: -f2)" = "note first" ] || fail "same-name output order changed"
pass "registry-before-directory barrier, directory_hook_after and same-name ordering honoured"

# 3. Blocks.
for c in a b ab; do
  reset_state
  case "$c" in *a*) : > "$ST/deny-a.on" ;; esac
  case "$c" in *b*) : > "$ST/deny-b.on" ;; esac
  run seq PreToolUse "blk-$c-seq"
  reset_state
  case "$c" in *a*) : > "$ST/deny-a.on" ;; esac
  case "$c" in *b*) : > "$ST/deny-b.on" ;; esac
  run par PreToolUse "blk-$c-par"
  [ "$(cat "$TMP/blk-$c-par.rc")" = 2 ] || fail "block case $c exited $(cat "$TMP/blk-$c-par.rc") in parallel"
  same "blk-$c-seq" "blk-$c-par" "block case $c"
done
grep -q 'deny-a blocked' "$TMP/blk-ab-par.err" && grep -q 'deny-b blocked' "$TMP/blk-ab-par.err" \
  || fail "two blocking guards: a block message is missing"
pass "single and double blocks exit 2 with identical output in both modes"

# 4. Missing result file blocks.
reset_state; : > "$ST/vanish.on"; run par PreToolUse vanish
[ "$(cat "$TMP/vanish.rc")" = 2 ] || fail "a guard with no result file exited $(cat "$TMP/vanish.rc"), want 2"
grep -q 'BLOCKED: vanish-guard left no result; failing closed.' "$TMP/vanish.err" || fail "missing-result message absent"
pass "a guard whose dispatch job died without a result blocks"

# 4b. A missing fail_closed guard script blocks in its dispatch position.
reset_state; : > "$FIX/workspace/gone-guard.on"; run seq PreToolUse gone-seq
reset_state; run par PreToolUse gone-par
rm -f "$FIX/workspace/gone-guard.on"
[ "$(cat "$TMP/gone-par.rc")" = 2 ] || fail "missing fail_closed script exited $(cat "$TMP/gone-par.rc") in parallel"
grep -q 'gone-guard guard script .claude/hooks/gone-guard.sh is missing' "$TMP/gone-par.err" || fail "missing-script message absent"
same gone-seq gone-par "missing fail_closed script"
pass "a missing fail_closed guard script blocks with identical output in both modes"

# 4c. No usable completion-marker dir: results fall back to a temp dir.
rm -rf "$FIX/workspace/.hook-timeout-completions"
: > "$FIX/workspace/.hook-timeout-completions"
reset_state; run seq PreToolUse nodir-seq
reset_state; run par PreToolUse nodir-par
rm -f "$FIX/workspace/.hook-timeout-completions"
[ "$(cat "$TMP/nodir-par.rc")" = 0 ] || fail "parallel run without a marker dir exited $(cat "$TMP/nodir-par.rc")"
same nodir-seq nodir-par "no completion-marker dir"
pass "parallel results fall back to a temp dir when the marker dir is unusable"

# 5. Shared safety budget across guards held back by the concurrency cap.
reset_state; : > "$ST/budget.on"
run par PreToolUse budget HQ_HOOK_PARALLEL_MAX=1 HQ_SAFETY_GUARD_TOTAL_BUDGET=3 HQ_SAFETY_GUARD_TIMEOUT=2
[ "$(cat "$TMP/budget.rc")" = 2 ] || fail "budget case exited $(cat "$TMP/budget.rc"), want 2"
grep -Eq 'slow-safety-1 did not finish within [12]s' "$TMP/budget.err" || fail "first slow guard was not capped"
grep -q 'time budget was spent before slow-safety-2 could run' "$TMP/budget.err" \
  || grep -q 'slow-safety-2 did not finish within 1s' "$TMP/budget.err" \
  || fail "second slow guard was not limited by the remaining budget"
[ "$(cat "$TMP/budget.sec")" -le 9 ] || fail "budget case took $(cat "$TMP/budget.sec")s"
pass "safety guards started late get only the remaining shared budget"

# 6. Per-child timeout breadcrumbs (watchdog on, two slow children at once).
reset_state
rm -rf "$FIX/workspace/.hook-timeout-journal"
(
  payload PreToolUse | env -i "HOME=$TMP" "PATH=$PATH" "TMPDIR=$TMP" "HQ_ROOT=$FIX" "CLAUDE_PROJECT_DIR=$FIX" \
    "BASH_ENV=/dev/null" HQ_HOOK_PARALLEL=1 "$BASH_BIN" "$H/master-hook.sh" PreToolUse >/dev/null 2>&1 || true
) &
bg=$!
max_seen=0
for _ in $(seq 1 40); do
  n=0
  for f in "$FIX"/workspace/.hook-timeout-journal/*.active.*; do
    [ -s "$f" ] && n=$((n + 1))
  done
  [ "$n" -le "$max_seen" ] || max_seen="$n"
  sleep 0.05
done
wait "$bg" || true
[ "$max_seen" -ge 2 ] || fail "saw $max_seen concurrent child breadcrumbs, want at least 2"
left=0
for f in "$FIX"/workspace/.hook-timeout-journal/*.active.*; do [ -e "$f" ] && left=$((left + 1)); done
[ "$left" -eq 0 ] || fail "$left per-child breadcrumbs left behind"
pass "each concurrent child has its own timeout breadcrumb, removed at exit"

# 7. Bash older than 5.1 stays sequential under the flag.
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" -lt 5 ]; then
  reset_state; run seq PreToolUse old-seq
  reset_state; payload PreToolUse | env -i "HOME=$TMP" "PATH=$PATH" "TMPDIR=$TMP" "HQ_ROOT=$FIX" \
    "CLAUDE_PROJECT_DIR=$FIX" "BASH_ENV=/dev/null" HQ_HOOK_TIMEOUT_SENTRY=0 HQ_SAFETY_GUARD_TIMEOUT=10 \
    HQ_HOOK_PARALLEL=1 /bin/bash "$H/master-hook.sh" PreToolUse >"$TMP/old-par.out" 2>"$TMP/old-par.err" \
    && printf 0 > "$TMP/old-par.rc" || printf '%s' "$?" > "$TMP/old-par.rc"
  cmp -s "$TMP/old-seq.out" "$TMP/old-par.out" || fail "bash 3.2 with the flag changed stdout"
  pass "bash 3.2 ignores HQ_HOOK_PARALLEL"
fi

echo "PASS: master-hook parallel dispatch"
