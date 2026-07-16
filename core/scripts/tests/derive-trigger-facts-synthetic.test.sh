#!/usr/bin/env bash
# hq-core: public
# Regression test for derive-trigger-facts.sh synthetic facts added for skill
# surfacing: `apikey`+`secret` from key-shaped strings, and `completed` from
# completion markers — plus no false positives on plain prose.
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "derive-trigger-facts-synthetic: skipped (jq missing)"; exit 0; }

ROOT="$(git rev-parse --show-toplevel)"
D="$ROOT/core/scripts/derive-trigger-facts.sh"
PASS=0; FAIL=0

# check <event> <json> <token> <want 0|1> <label>
check() {
  local ev="$1" j="$2" tok="$3" want="$4" label="$5" facts has=0
  facts="$(printf '%s' "$j" | bash "$D" "$ev" 2>/dev/null)"
  case " $facts " in *" $tok "*) has=1 ;; esac
  if [ "$has" -eq "$want" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL[$label]: '$tok' present=$has want=$want :: $facts" >&2; fi
}

check UserPromptSubmit '{"prompt":"the value AKIAIOSFODNN7EXAMPLE goes here"}' apikey 1 'AKIA->apikey'
check UserPromptSubmit '{"prompt":"the value AKIAIOSFODNN7EXAMPLE goes here"}' secret 1 'AKIA->secret'
check UserPromptSubmit '{"prompt":"export K=sk-abcd0123456789abcdef0"}'        apikey 1 'sk-->apikey'
check UserPromptSubmit '{"prompt":"token ghp_abcdefghijklmnop0123456789"}'      apikey 1 'ghp_->apikey'
check UserPromptSubmit '{"prompt":"refactor the api route and a password field"}' apikey 0 'plain api/password->no apikey'
check PostToolUse '{"tool_name":"Bash","tool_response":"Successfully merged pull request #1"}' completed 1 'merge->completed'
check PostToolUse '{"tool_name":"Bash","tool_response":"deployment complete at https://x.app"}' completed 1 'deploy->completed'
check UserPromptSubmit '{"prompt":"please refactor a helper function"}'         completed 0 'plain->no completed'

echo "derive-trigger-facts-synthetic: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
