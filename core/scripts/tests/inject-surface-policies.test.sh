#!/usr/bin/env bash
# hq-core: public
# Regression test: the two skill-surfacing policies inject at the right moment,
# and a swept secret guardrail now fires on plain conversation (not just on a
# Bash command).
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "inject-surface-policies: skipped (jq missing)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "inject-surface-policies: skipped (python3 missing)"; exit 0; }

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
STATE="$ROOT/workspace/orchestrator/policy-trigger-state"
PASS=0; FAIL=0; n=0

# run <json-with-__SID__> <slug> <want 0|1> <label>  (unique session id → no dedupe bleed)
run() {
  local j="$1" slug="$2" want="$3" label="$4"
  n=$((n+1)); local sid="injtest-$$-$n" out has=0
  j="${j//__SID__/$sid}"
  out="$(printf '%s' "$j" | HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" 2>/dev/null || true)"
  case "$out" in *"$slug"*) has=1 ;; esac
  rm -f "$STATE/$sid.txt" 2>/dev/null || true
  if [ "$has" -eq "$want" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL[$label]: '$slug' present=$has want=$want" >&2; fi
}

run '{"hook_event_name":"UserPromptSubmit","session_id":"__SID__","cwd":"'"$ROOT"'","prompt":"rotate the api key and reset the db password"}' \
    'hq-surface-hq-secrets-on-secret-discussion' 1 'secrets prompt -> surface hq-secrets'
run '{"hook_event_name":"UserPromptSubmit","session_id":"__SID__","cwd":"'"$ROOT"'","prompt":"rotate the api key and reset the db password"}' \
    'credential-access-protocol' 1 'secrets prompt -> swept guardrail fires on chat'
run '{"hook_event_name":"PostToolUse","session_id":"__SID__","tool_name":"Bash","cwd":"'"$ROOT"'","tool_response":"Merged pull request #291 and deployed live"}' \
    'hq-surface-share-on-completion' 1 'merge result -> surface share-on-completion'
run '{"hook_event_name":"UserPromptSubmit","session_id":"__SID__","cwd":"'"$ROOT"'","prompt":"what time is the standup tomorrow"}' \
    'hq-surface-hq-secrets-on-secret-discussion' 0 'unrelated -> no secrets surface'
run '{"hook_event_name":"UserPromptSubmit","session_id":"__SID__","cwd":"'"$ROOT"'","prompt":"what time is the standup tomorrow"}' \
    'hq-surface-share-on-completion' 0 'unrelated -> no share surface'

echo "inject-surface-policies: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
