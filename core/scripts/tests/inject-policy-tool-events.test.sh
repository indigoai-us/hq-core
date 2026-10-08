#!/usr/bin/env bash
# Regression contract for policy reminder delivery by tool event.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
TMP="$(mktemp -d)"
trap '[ "${HP17_KEEP_TMP:-0}" = 1 ] || rm -rf "$TMP"' EXIT
mkdir -p "$TMP/core/policies"
cat > "$TMP/core/policies/tool-event-default.md" <<'EOF'
---
when: git && push
---
## Rule
Default tool event fixture.
EOF
cat > "$TMP/core/policies/tool-event-post.md" <<'EOF'
---
when: completed
on: [PostToolUse]
---
## Rule
Post tool event fixture.
EOF
cat > "$TMP/core/policies/tool-event-pre.md" <<'EOF'
---
when: git && push
on: [PreToolUse]
---
## Rule
Explicit PreToolUse fixture.
EOF
cat > "$TMP/core/policies/tool-event-background-only.md" <<'EOF'
---
when: run_in_background
---
## Rule
Background marker is only available before the tool call.
EOF

failures=0
check() {
  local label="$1" ok="$2"
  if [ "$ok" = 1 ]; then printf 'ok   %s\n' "$label"; else printf 'FAIL %s\n' "$label"; failures=$((failures+1)); fi
}
run_hook() {
  local sid="$1" event="$2" harness="$3" legacy="$4" output="$5" command="$6" response="$7"
  jq -cn --arg sid "$sid" --arg event "$event" --arg command "$command" --arg response "$response" \
    '{session_id:$sid,hook_event_name:$event,tool_name:"Bash",cwd:"/tmp",tool_input:{command:$command},tool_response:$response}' \
    | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HARNESS="$harness" HQ_POLICY_TOOL_EVENTS="$legacy" \
      bash "$HOOK" > "$output" 2>"$TMP/stderr"
}

run_hook pre-default PreToolUse claude off "$TMP/pre-default" 'git push origin test' ''
check 'PreToolUse default emits nothing' "$( [ ! -s "$TMP/pre-default" ] && echo 1 || echo 0 )"
check 'PreToolUse default ledgers no slug' "$( [ ! -e "$TMP/workspace/orchestrator/policy-trigger-state/pre-default.txt" ] && echo 1 || echo 0 )"

run_hook post-default PostToolUse claude off "$TMP/post-default" 'git push origin test' 'completed'
check 'PostToolUse command facts match omitted on' "$(jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | contains("tool-event-default"))' "$TMP/post-default" >/dev/null 2>&1 && echo 1 || echo 0)"
check 'PostToolUse is a JSON additionalContext envelope' "$(jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | type == "string")' "$TMP/post-default" >/dev/null 2>&1 && echo 1 || echo 0)"

jq -cn '{session_id:"post-background",hook_event_name:"PostToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:"echo done",run_in_background:true},tool_response:{stdout:"done"}}' \
  | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HARNESS=claude HQ_POLICY_TOOL_EVENTS=off \
    bash "$HOOK" > "$TMP/post-background" 2>"$TMP/stderr"
check 'PostToolUse command facts do not recreate the PreToolUse-only background marker' "$( [ ! -s "$TMP/post-background" ] && echo 1 || echo 0 )"

FAIL_ROOT="$TMP/derive-failure"
mkdir -p "$FAIL_ROOT/.claude/hooks" "$FAIL_ROOT/core/scripts" "$FAIL_ROOT/core/policies"
cp "$HOOK" "$FAIL_ROOT/.claude/hooks/inject-policy-on-trigger.sh"
cp "$ROOT/core/scripts/hook-lib.sh" "$FAIL_ROOT/core/scripts/hook-lib.sh"
cat > "$FAIL_ROOT/core/scripts/eval-trigger.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAIL_ROOT/core/scripts/derive-trigger-facts.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'derive-trigger-facts.sh: simulated failure' >&2
exit 127
EOF
chmod +x "$FAIL_ROOT/core/scripts/eval-trigger.sh" "$FAIL_ROOT/core/scripts/derive-trigger-facts.sh"
if jq -cn '{session_id:"post-derive-failure",hook_event_name:"PostToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:"git push origin test"},tool_response:{exit_code:0}}' | env HQ_ROOT="$FAIL_ROOT" CLAUDE_PROJECT_DIR="$FAIL_ROOT" HQ_HARNESS=claude HQ_POLICY_TOOL_EVENTS=off HQ_POLICY_FACT_HELPER_DISABLE=1 bash "$FAIL_ROOT/.claude/hooks/inject-policy-on-trigger.sh" > "$TMP/post-derive-failure" 2> "$TMP/post-derive-failure.stderr"; then
  failed_derive_rc=0
else
  failed_derive_rc=$?
fi
printf '%s\n' 'derive-trigger-facts.sh: simulated failure' > "$TMP/post-derive-failure.expected"
check 'PostToolUse failed derive exits zero and emits no stdout' "$( [ "$failed_derive_rc" -eq 0 ] && [ ! -s "$TMP/post-derive-failure" ] && echo 1 || echo 0 )"
check 'PostToolUse failed derive stderr is emitted once' "$(cmp -s "$TMP/post-derive-failure.expected" "$TMP/post-derive-failure.stderr" && echo 1 || echo 0)"

run_hook pre-legacy PreToolUse claude legacy "$TMP/pre-legacy" 'git push origin test' ''
check 'legacy restores PreToolUse policy evaluation' "$(grep -q 'tool-event-pre' "$TMP/pre-legacy" && echo 1 || echo 0)"
check 'legacy restores omitted-on PreToolUse default' "$(grep -q 'tool-event-default' "$TMP/pre-legacy" && echo 1 || echo 0)"

run_hook post-grok PostToolUse grok off "$TMP/post-grok" 'git push origin test' 'completed'
check 'Grok PostToolUse skips policy evaluation' "$( [ ! -s "$TMP/post-grok" ] && echo 1 || echo 0 )"
check 'Grok PostToolUse ledgers no slug' "$( [ ! -e "$TMP/workspace/orchestrator/policy-trigger-state/post-grok.txt" ] && echo 1 || echo 0 )"

helper_output_is_deliverable() {
  local file="$1"
  [ ! -s "$file" ] || jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | type == "string")' "$file" >/dev/null 2>&1
}
HELPER_PAYLOAD="$(jq -cn '{session_id:"hp17-helper",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"git commit -m hp17"},tool_response:{exit_code:0}}')"
printf '%s' "$HELPER_PAYLOAD" | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/.claude/hooks/auto-checkpoint-trigger.sh" > "$TMP/auto-helper"
check 'auto-checkpoint PostToolUse output is enveloped or empty' "$(helper_output_is_deliverable "$TMP/auto-helper" && echo 1 || echo 0)"
printf '%s' "$HELPER_PAYLOAD" | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/.claude/hooks/journal-due.sh" > "$TMP/journal-helper"
check 'journal-due PostToolUse output is enveloped or empty' "$(helper_output_is_deliverable "$TMP/journal-helper" && echo 1 || echo 0)"
printf '%s' '{"session_id":"hp17-helper","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"sst deploy"}}' \
  | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/.claude/hooks/surface-company-infra-policy.sh" > "$TMP/surface-helper"
check 'surface-company-infra PreToolUse output is empty' "$( [ ! -s "$TMP/surface-helper" ] && echo 1 || echo 0 )"

check 'registry binds surface helper to PreToolUse' "$(jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.id == "surface-company-infra-policy")] | length == 1' "$ROOT/.claude/hooks/hook-registry.json" >/dev/null && echo 1 || echo 0)"
check 'registry binds journal and checkpoint helpers to PostToolUse' "$(jq -e '[.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.id == "journal-due" or .id == "auto-checkpoint-trigger")] | length == 2' "$ROOT/.claude/hooks/hook-registry.json" >/dev/null && echo 1 || echo 0)"

printf '\n==== inject-policy-tool-events: %s failures ====\n' "$failures"
[ "$failures" -eq 0 ]
