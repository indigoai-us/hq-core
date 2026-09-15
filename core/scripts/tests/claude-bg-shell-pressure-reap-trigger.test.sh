#!/usr/bin/env bash
# hq-core: public
# claude-bg-shell-pressure-reap-trigger.test.sh — pins the trigger for
# core/policies/claude-bg-shell-pressure-reap.md and the structured
# `run_in_background` fact it depends on (core/scripts/derive-trigger-facts.sh).
#
#   1. derive-trigger-facts emits `run_in_background` only for a PreToolUse Bash
#      call with tool_input.run_in_background == true (not false, absent, or a
#      non-Bash tool).
#   2. The policy's real `when:` (read from the file, not copied) fires on
#      every backgrounded Bash call (any of them can be reaped, including a
#      script whose poll loop is not visible in the command) and on prompts
#      about low-memory / OOM kills, and does NOT fire on the same commands run
#      in the foreground or on unrelated prompts.
#
# Explicitly wired into .github/workflows/pr-checks.yml — tests here are NOT
# auto-discovered.
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "claude-bg-shell-pressure-reap-trigger: skipped (jq missing)"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
D="$ROOT/core/scripts/derive-trigger-facts.sh"
EV="$ROOT/core/scripts/eval-trigger.sh"
POLICY="$ROOT/core/policies/claude-bg-shell-pressure-reap.md"
WHEN="$(awk '/^---$/{n++; next} n==1 && /^when:/{sub(/^when:[ \t]*/, ""); print; exit}' "$POLICY")"
PASS=0; FAIL=0

[ -n "$WHEN" ] || { echo "FAIL: could not read when: from $POLICY"; exit 1; }

facts() { printf '%s' "$2" | HQ_ROOT="$ROOT" bash "$D" "$1" 2>/dev/null; }

# has_fact <event> <json> <want 0|1> <label>
has_fact() {
  local f has=0
  f="$(facts "$1" "$2")"
  case " $f " in *" run_in_background "*) has=1 ;; esac
  if [ "$has" -eq "$3" ]; then PASS=$((PASS+1)); echo "ok   [$4]"
  else FAIL=$((FAIL+1)); echo "FAIL [$4]: run_in_background present=$has want=$3 :: $f"; fi
}

# fires <event> <json> <want 0|1> <label>
fires() {
  local f rc
  f="$(facts "$1" "$2")"
  bash "$EV" "$WHEN" "$f" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then FAIL=$((FAIL+1)); echo "FAIL [$4]: when: is malformed: $WHEN"; return; fi
  local got=$(( rc == 0 ? 1 : 0 ))
  if [ "$got" -eq "$3" ]; then PASS=$((PASS+1)); echo "ok   [$4]"
  else FAIL=$((FAIL+1)); echo "FAIL [$4]: fired=$got want=$3 :: facts=$f"; fi
}

POLL='until grep -q done /tmp/run.log; do sleep 120; done'

# 1. fact derivation
has_fact PreToolUse "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$POLL\",\"run_in_background\":true}}" 1 'bg true -> fact'
has_fact PreToolUse "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$POLL\",\"run_in_background\":false}}" 0 'bg false -> no fact'
has_fact PreToolUse "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$POLL\"}}" 0 'bg absent -> no fact'
has_fact PostToolUse "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$POLL\",\"run_in_background\":true},\"tool_response\":\"ok\"}" 0 'PostToolUse -> no fact'
has_fact PreToolUse '{"tool_name":"Monitor","tool_input":{"run_in_background":true}}' 0 'non-Bash tool -> no fact'

# 2. policy trigger
fires PreToolUse "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$POLL\",\"run_in_background\":true}}" 1 'background until/sleep poll'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"sleep 300; gh run view 42","run_in_background":true}}' 1 'background plain sleep'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"tail -f /tmp/build.log","run_in_background":true}}' 1 'background tail -f'
fires PreToolUse "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$POLL\"}}" 0 'foreground poll loop -> silent'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"while read l; do echo \"$l\"; sleep 1; done < f"}}' 0 'foreground while/sleep -> silent'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"./poll-status.sh","run_in_background":true}}' 1 'background opaque poll script'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"pnpm run build","run_in_background":true}}' 1 'background build (reapable too)'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"pnpm run build"}}' 0 'foreground build -> silent'
fires UserPromptSubmit '{"prompt":"Background command was stopped because the system is running low on memory"}' 1 'kill message prompt'
fires UserPromptSubmit '{"prompt":"my poller keeps dying, OOM?"}' 1 'oom poller prompt'
fires UserPromptSubmit '{"prompt":"refactor the memory cache helper"}' 0 'unrelated memory prompt -> silent'

# 3. detach recipe: run the documented Linux recipe verbatim (short deadline,
#    multi-argument command) and assert it really detaches, records the waiter's
#    PID, and passes every argument through. Never the in-place `setsid nohup`.
if grep -qF 'setsid nohup timeout' "$POLICY"; then FAIL=$((FAIL+1)); echo "FAIL [no in-place setsid recipe]"
else PASS=$((PASS+1)); echo "ok   [no in-place setsid recipe]"; fi

LAUNCH="$(grep -m1 -E '^[[:space:]]*setsid --fork ' "$POLICY" | sed -E 's/^[[:space:]]+//')"
WAIT="$(grep -m1 -E '^[[:space:]]*for _ in .*poll\.pid' "$POLICY" | sed -E 's/^[[:space:]]+//')"
CLEAR="$(grep -m1 -E '^[[:space:]]*rm -f "\$dir/poll\.pid"' "$POLICY" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+#.*$//')"
if [ -z "$LAUNCH" ] || [ -z "$WAIT" ] || [ -z "$CLEAR" ]; then
  FAIL=$((FAIL+1)); echo "FAIL [recipe present]: clear, launch or wait line missing from $POLICY"
elif [ "$(uname -s)" != "Linux" ] || ! setsid --help 2>&1 | grep -q -- '--fork'; then
  echo "skip [recipe executes]: needs Linux util-linux setsid --fork"
else
  PASS=$((PASS+1)); echo "ok   [recipe present]"
  dir="$(mktemp -d)"
  LAUNCH="${LAUNCH//timeout 2h/timeout 30}"
  # a literal `}` in an inline replacement would close the expansion early
  cmd_ref='"${CMD[@]}"'
  LAUNCH="${LAUNCH//<command> \[args...\]/$cmd_ref}"
  CMD=(sh -c 'printf "%s|%s|%s\n" "$1" "$2" "$3" >"$0"; sleep 20' "$dir/args.out" "one two" three four)
  # directory reuse: a stale PID from a previous waiter must not satisfy the wait
  echo 999999 >"$dir/poll.pid"
  eval "$CLEAR"
  eval "$LAUNCH"
  eval "$WAIT"
  pid="$(cat "$dir/poll.pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && [ "$pid" != 999999 ]; then PASS=$((PASS+1)); echo "ok   [fresh pid file written]"
  else FAIL=$((FAIL+1)); echo "FAIL [pid file written]: $dir/poll.pid empty after bounded wait"; fi
  ppid="$( [ -n "$pid" ] && ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  # detached == reparented away from the launching shell (1, or a subreaper)
  if [ -n "$ppid" ] && [ "$ppid" != "$$" ]; then PASS=$((PASS+1)); echo "ok   [detached from shell ppid=$ppid]"
  else FAIL=$((FAIL+1)); echo "FAIL [detached from shell]: ppid='$ppid' shell=$$ pid='$pid'"; fi
  for _ in $(seq 50); do [ -s "$dir/args.out" ] && break; sleep 0.1; done
  if [ "$(cat "$dir/args.out" 2>/dev/null)" = "one two|three|four" ]; then PASS=$((PASS+1)); echo "ok   [all args passed]"
  else FAIL=$((FAIL+1)); echo "FAIL [all args passed]: got '$(cat "$dir/args.out" 2>/dev/null)'"; fi
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  rm -rf "$dir"
fi

echo "claude-bg-shell-pressure-reap-trigger: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
