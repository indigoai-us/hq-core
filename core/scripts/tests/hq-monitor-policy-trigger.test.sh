#!/usr/bin/env bash
# Covers the policy's live trigger expression through the production fact tools.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
POLICY="$ROOT/core/policies/hq-monitor-for-long-running-waits.md"
DERIVE="$ROOT/core/scripts/derive-trigger-facts.sh"
EVAL="$ROOT/core/scripts/eval-trigger.sh"
WHEN="$(awk '/^---$/{n++; next} n==1 && /^when:/{sub(/^when:[ \t]*/, ""); print; exit}' "$POLICY")"
PASS=0
FAIL=0

[ -n "$WHEN" ] || { echo "FAIL: no when expression in $POLICY"; exit 1; }
if [ "$(wc -l < "$POLICY" | tr -d ' ')" -le 45 ] && [ "$(wc -c < "$POLICY" | tr -d ' ')" -le 2048 ]; then
  PASS=$((PASS + 1)); echo 'ok   [hard policy stays below its injection size budget]'
else
  FAIL=$((FAIL + 1)); echo 'FAIL [hard policy stays below its injection size budget]'
fi
for required in \
  'Prompt caching only works within an hour.' \
  'every 55 minutes' \
  'lower price' \
  '--checkin off' \
  'Silence is not success.' \
  'grep --line-buffered'
do
  if grep -Fq -- "$required" "$POLICY"; then PASS=$((PASS + 1)); echo "ok   [policy includes $required]"; else FAIL=$((FAIL + 1)); echo "FAIL [policy includes $required]"; fi
done
if ! grep -Eiq 'do not wake.*cache warm|do not.*wake.*keep.*cache' "$POLICY"; then PASS=$((PASS + 1)); echo 'ok   [policy has no stale cache-wake restriction]'; else FAIL=$((FAIL + 1)); echo 'FAIL [policy has no stale cache-wake restriction]'; fi
facts() { printf '%s' "$2" | HQ_ROOT="$ROOT" bash "$DERIVE" "$1" 2>/dev/null; }
fires() {
  local event="$1" json="$2" expected="$3" label="$4" result rc
  result="$(facts "$event" "$json")"
  bash "$EVAL" "$WHEN" "$result" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then
    FAIL=$((FAIL + 1)); echo "FAIL [$label]: malformed trigger $WHEN"
  elif { [ "$rc" -eq 0 ] && [ "$expected" -eq 1 ]; } || { [ "$rc" -eq 1 ] && [ "$expected" -eq 0 ]; }; then
    PASS=$((PASS + 1)); echo "ok   [$label]"
  else
    FAIL=$((FAIL + 1)); echo "FAIL [$label]: fired=$((rc == 0 ? 1 : 0)) expected=$expected facts=$result"
  fi
}

echo '[1] normalized shell events from each runtime trigger on the same policy'
for runtime in Claude Codex Grok; do
  fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"gh run watch 123"}}' 1 "$runtime gh run watch"
done
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"sleep 30"}}' 1 'foreground sleep'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"until grep -q complete status; do sleep 30; done"}}' 1 'until poll loop'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"gh pr checks --watch"}}' 1 'gh pr checks watch'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"wait-for ready"}}' 1 'wait-for command'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"poll status"}}' 1 'poll command'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"while grep -q done state; do sleep 2; done"}}' 1 'while loop'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"hq monitor start --description wait --command true --persistent"}}' 1 'hq monitor command'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"sleep 300","run_in_background":true}}' 1 'background sleep'
fires UserPromptSubmit '{"prompt":"Please monitor this CI run for a terminal state"}' 1 'monitor prompt'

echo '[2] ordinary commands do not trigger the hard policy'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"ls"}}' 0 'ls'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"git status"}}' 0 'git status'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' 0 'npm test'
fires UserPromptSubmit '{"prompt":"while you are at it, fix the typo"}' 0 'ordinary while prompt'
fires UserPromptSubmit '{"prompt":"loop over the files and rename them"}' 0 'ordinary loop prompt'
fires PreToolUse '{"tool_name":"Bash","tool_input":{"command":"while (ready) { updateFiles(); }"}}' 0 'plain while loop without a wait'
fires PreToolUse '{"tool_name":"Edit","tool_input":{"new_string":"while (ready) { updateFiles(); }"}}' 0 'edit with plain while loop and no wait'

echo "hq-monitor-policy-trigger: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
