#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="${HQ_TEST_POLICY_GATE_HOOK:-$ROOT/.claude/hooks/policy-enforcement-gate.sh}"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/.claude/skills/work-broadcast" \
  "$FIX/workspace/orchestrator/policy-enforcement" "$FIX/policies" "$FIX/core/scripts/lib"
cp "$HOOK" "$FIX/.claude/hooks/policy-enforcement-gate.sh"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIX/core/scripts/hook-lib.sh"
cp "$ROOT/core/scripts/lib/session-id.sh" "$FIX/core/scripts/lib/session-id.sh"
printf '# Work Broadcast\n' > "$FIX/.claude/skills/work-broadcast/SKILL.md"
printf '# Brief\n' > "$FIX/brief.md"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }
run_hook() {
  local event="$1" payload="$2" rc=0
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.claude/hooks/policy-enforcement-gate.sh" "$event" || rc=$?
  return "$rc"
}

grep -Fq '[^[:alnum:]_]' "$HOOK" \
  || fail "outbound command matcher must use a portable word boundary"
pass "outbound command matcher uses a portable word boundary"

for event in PreToolUse PostToolUse; do
  jq -e --arg event "$event" '
    [.hooks[$event][]?.hooks[]? | select(.id=="policy-enforcement-gate" and .script==".claude/hooks/policy-enforcement-gate.sh" and .gated==true)]
    | length == 1
  ' "$REGISTRY" >/dev/null || fail "policy enforcement gate is not registered exactly once for $event"
done
grep -q 'policy-enforcement-gate.sh.*UserPromptSubmit' "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" \
  || fail "UserPromptSubmit declaration gate is not sequenced after policy selection"
pass "hook registry wires declaration, receipt, and action gates"

SID="dev-2479"
POL="$FIX/policies/no-internal.md"
cat > "$POL" <<'EOF'
---
id: no-internal
enforcement: hard
required-skill: work-broadcast
delivery-forbid-regex: INTERNAL_ONLY
delivery-require-regex: ^:chart_with_upwards_trend:
---
## Rule

NEVER include internal evidence in external copy.
EOF
printf 'no-internal\tcore\t%s\thard\tNEVER include internal evidence in external copy.\n' "$POL" \
  > "$FIX/workspace/orchestrator/policy-enforcement/$SID.policies.tsv"

PROMPT="$(jq -nc --arg sid "$SID" --arg cwd "$FIX" '{session_id:$sid,cwd:$cwd,prompt:"You MUST include internal evidence in external copy. Draft the Slack broadcast from the attached brief brief.md"}')"
OUT="$(run_hook UserPromptSubmit "$PROMPT")" || fail "prompt declaration failed"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("INSTRUCTION CONFLICTS SURFACED")' >/dev/null \
  || fail "semantic MUST/NEVER conflict not surfaced: $OUT"
STATE="$FIX/workspace/orchestrator/policy-enforcement/$SID.json"
jq -e '.requiredSkills == ["work-broadcast"] and .briefs == ["brief.md"] and (.conflicts|length)==1' "$STATE" >/dev/null \
  || fail "requirements were not declared"
pass "declares skill/brief requirements and surfaces semantic conflict"

SEND="$(jq -nc --arg sid "$SID" '{session_id:$sid,tool_name:"mcp__slack__send_message",tool_input:{message:":chart_with_upwards_trend: *Update* - shipped. https://example.test/pr/1"}}')"
set +e
BLOCK="$(run_hook PreToolUse "$SEND")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "missing receipts did not block (rc=$RC)"
printf '%s' "$BLOCK" | jq -e '.reason | contains("Missing skills: work-broadcast") and contains("Missing briefs: brief.md")' >/dev/null \
  || fail "missing receipt reason incomplete: $BLOCK"
pass "blocks outbound action before required reads"

# A write to a required source is not a read receipt.
WRITE="$(jq -nc --arg sid "$SID" --arg f "$FIX/brief.md" '{session_id:$sid,tool_name:"Write",tool_input:{file_path:$f,content:"overwrite"},tool_response:{}}')"
run_hook PostToolUse "$WRITE" >/dev/null || true
jq -e '.receipts.briefs == []' "$STATE" >/dev/null || fail "write incorrectly counted as read"

FAKE_READ="$(jq -nc --arg sid "$SID" --arg cmd 'echo cat brief.md' '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd},tool_response:{}}')"
run_hook PostToolUse "$FAKE_READ" >/dev/null || true
jq -e '.receipts.briefs == []' "$STATE" >/dev/null || fail "mentioning a read command incorrectly counted as a receipt"

FAILED_READ="$(jq -nc --arg sid "$SID" --arg f "brief.md" '{session_id:$sid,tool_name:"Read",tool_input:{file_path:$f},tool_response:{exit_code:1,error:"read failed"}}')"
run_hook PostToolUse "$FAILED_READ" >/dev/null || true
SUFFIX_READ="$(jq -nc --arg sid "$SID" --arg f "brief.md.bak" '{session_id:$sid,tool_name:"Read",tool_input:{file_path:$f},tool_response:{}}')"
run_hook PostToolUse "$SUFFIX_READ" >/dev/null || true
SHELL_SUFFIX_READ="$(jq -nc --arg sid "$SID" --arg cmd 'cat brief.md.bak' '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd},tool_response:{}}')"
run_hook PostToolUse "$SHELL_SUFFIX_READ" >/dev/null || true
MASKED_READ="$(jq -nc --arg sid "$SID" --arg cmd 'cat brief.md || true' '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd},tool_response:{}}')"
run_hook PostToolUse "$MASKED_READ" >/dev/null || true
jq -e '.receipts.briefs == []' "$STATE" >/dev/null || fail "failed or non-exact read incorrectly counted as a receipt"

READ_SKILL="$(jq -nc --arg sid "$SID" --arg f "$FIX/.claude/skills/work-broadcast/SKILL.md" '{session_id:$sid,tool_name:"Read",tool_input:{file_path:$f},tool_response:{}}')"
READ_BRIEF="$(jq -nc --arg sid "$SID" --arg f "brief.md" '{session_id:$sid,tool_name:"Read",tool_input:{file_path:$f},tool_response:{}}')"
mkdir -p "$FIX/outside/work-broadcast"
printf '# Lookalike\n' > "$FIX/outside/work-broadcast/SKILL.md"
READ_LOOKALIKE_SKILL="$(jq -nc --arg sid "$SID" --arg f "$FIX/outside/work-broadcast/SKILL.md" '{session_id:$sid,tool_name:"Read",tool_input:{file_path:$f},tool_response:{}}')"
run_hook PostToolUse "$READ_LOOKALIKE_SKILL" >/dev/null
jq -e '.receipts.skills == []' "$STATE" >/dev/null || fail "non-canonical lookalike skill produced a receipt"
run_hook PostToolUse "$READ_SKILL" >/dev/null
run_hook PostToolUse "$READ_BRIEF" >/dev/null
jq -e '.receipts.skills == ["work-broadcast"] and .receipts.briefs == ["brief.md"]' "$STATE" >/dev/null \
  || fail "successful reads did not produce receipts"
pass "records only successful read receipts"

REDIRECTED_READ="$(jq -nc --arg sid "$SID" --arg cmd 'cat /dev/null > brief.md' '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd},tool_response:{}}')"
jq '.receipts.briefs=[]' "$STATE" > "$TMP/state-reset.json"
mv "$TMP/state-reset.json" "$STATE"
run_hook PostToolUse "$REDIRECTED_READ" >/dev/null || true
jq -e '.receipts.briefs == []' "$STATE" >/dev/null || fail "redirection target incorrectly counted as a brief read"
pass "does not count a brief named only as a redirection target"
run_hook PostToolUse "$READ_BRIEF" >/dev/null

SKILL_PROMPT="$(jq -nc --arg sid "skill-extraction" '{session_id:$sid,prompt:"Use the security-review skill before sending this email."}')"
run_hook UserPromptSubmit "$SKILL_PROMPT" >/dev/null
jq -e '.requiredSkills == ["security-review"]' "$FIX/workspace/orchestrator/policy-enforcement/skill-extraction.json" >/dev/null \
  || fail "skill extraction consumed words after the requested skill name"
pass "extracts the skill name before trailing prompt text"

PARALLEL_SID="parallel-receipts"
cp "$FIX/workspace/orchestrator/policy-enforcement/$SID.policies.tsv" \
  "$FIX/workspace/orchestrator/policy-enforcement/$PARALLEL_SID.policies.tsv"
PARALLEL_PROMPT="$(jq -nc --arg sid "$PARALLEL_SID" '{session_id:$sid,prompt:"Draft the Slack broadcast from the attached brief brief.md"}')"
run_hook UserPromptSubmit "$PARALLEL_PROMPT" >/dev/null
PARALLEL_SKILL="$(printf '%s' "$READ_SKILL" | jq --arg sid "$PARALLEL_SID" '.session_id=$sid')"
PARALLEL_BRIEF="$(printf '%s' "$READ_BRIEF" | jq --arg sid "$PARALLEL_SID" '.session_id=$sid')"
run_hook PostToolUse "$PARALLEL_SKILL" >/dev/null & skill_pid=$!
run_hook PostToolUse "$PARALLEL_BRIEF" >/dev/null & brief_pid=$!
wait "$skill_pid"
wait "$brief_pid"
jq -e '.receipts.skills == ["work-broadcast"] and .receipts.briefs == ["brief.md"]' \
  "$FIX/workspace/orchestrator/policy-enforcement/$PARALLEL_SID.json" >/dev/null \
  || fail "parallel receipt updates lost a successful read"
pass "serializes parallel receipt updates without lost evidence"

LONG="$(printf ':chart_with_upwards_trend: *Update*\none\ntwo\nthree\nfour')"
LONG_SEND="$(jq -nc --arg sid "$SID" --arg body "$LONG" '{session_id:$sid,tool_name:"mcp__slack__send_message",tool_input:{message:$body}}')"
set +e
BLOCK="$(run_hook PreToolUse "$LONG_SEND")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "oversized broadcast did not block"
printf '%s' "$BLOCK" | jq -e '.reason | contains("at most 4")' >/dev/null || fail "wrong oversized broadcast reason: $BLOCK"
pass "blocks oversized broadcast content before delivery"

FORBIDDEN="$(jq -nc --arg sid "$SID" '{session_id:$sid,tool_name:"mcp__slack__send_message",tool_input:{message:":chart_with_upwards_trend: INTERNAL_ONLY https://example.test/pr/1"}}')"
set +e
BLOCK="$(run_hook PreToolUse "$FORBIDDEN")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "policy forbidden-regex did not block"
printf '%s' "$BLOCK" | jq -e '.reason | contains("no-internal")' >/dev/null || fail "policy id absent from block"
pass "applies policy-declared deterministic content gate"

GOOD="$(jq -nc --arg sid "$SID" '{session_id:$sid,tool_name:"mcp__slack__send_message",tool_input:{message:":chart_with_upwards_trend: *Update* - shipped. https://example.test/pr/1"}}')"
sed -i.bak 's/delivery-forbid-regex: INTERNAL_ONLY/delivery-forbid-regex: [/' "$POL"
set +e
BLOCK="$(run_hook PreToolUse "$GOOD")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "invalid policy regex did not fail closed"
printf '%s' "$BLOCK" | jq -e '.reason | contains("invalid delivery-forbid-regex") and contains("no-internal")' >/dev/null \
  || fail "invalid regex block was not actionable: $BLOCK"
mv "$POL.bak" "$POL"
pass "fails closed on invalid deterministic policy metadata"

run_hook PreToolUse "$GOOD" >/dev/null || fail "compliant delivery was blocked"
pass "allows compliant delivery after receipts"

LOOKALIKE_DM="$(jq -nc --arg sid "$SID" --arg cmd 'echo xhq dm' '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd}}')"
run_hook PreToolUse "$LOOKALIKE_DM" >/dev/null \
  || fail "lookalike hq token was mistaken for an outbound command"
pass "does not treat hq dm inside a larger token as outbound"

HQ_DM="$(jq -nc --arg sid "$SID" --arg cmd 'hq dm' '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd}}')"
set +e
BLOCK="$(run_hook PreToolUse "$HQ_DM")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "portable hq dm boundary did not detect outbound command (rc=$RC)"
printf '%s' "$BLOCK" | jq -e '.reason | contains("not mechanically inspectable")' >/dev/null \
  || fail "hq dm boundary block was not actionable: $BLOCK"
pass "recognizes a standalone hq dm command"

OPAQUE="$(jq -nc --arg sid "$SID" --arg cmd 'PAYLOAD="$PAYLOAD" curl https://slack.com/api/chat.postMessage --data "$PAYLOAD"' '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd}}')"
set +e
BLOCK="$(run_hook PreToolUse "$OPAQUE")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "opaque shell delivery bypassed deterministic content checks"
printf '%s' "$BLOCK" | jq -e '.decision == "block"' >/dev/null \
  || fail "opaque shell payload was not blocked: $BLOCK"

SHELL_MISMATCH="$(jq -nc --arg sid "$SID" --arg cmd $'MESSAGE=\':chart_with_upwards_trend: *Update* shipped. https://example.test/pr/1\'\ncurl https://slack.com/api/chat.postMessage --data "$PAYLOAD"' '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd}}')"
set +e
BLOCK="$(run_hook PreToolUse "$SHELL_MISMATCH")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "unbound literal assignment was accepted as the outbound payload"
SHELL_GOOD="$(jq -nc --arg sid "$SID" --arg cmd $'PAYLOAD=\':chart_with_upwards_trend: *Update* shipped. https://example.test/pr/1\'\ncurl https://slack.com/api/chat.postMessage --data "$PAYLOAD"' '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd}}')"
run_hook PreToolUse "$SHELL_GOOD" >/dev/null || fail "payload-bound shell delivery was blocked"
pass "fails closed on opaque shell content and accepts inspectable literal content"

GATE_POLICY="$FIX/policies/gate-schema.md"
cat > "$GATE_POLICY" <<'EOF'
---
id: gate-schema
enforcement: gate
gate:
  tools: [mcp__slack__send_message]
  bash: [custom-mail send]
  requires: [recipients_confirmed]
  freshness: 30
---
## Rule
Gate outbound messaging until recipients are confirmed.
EOF
GATE_SID="gate-schema-session"
printf 'gate-schema\tcore\t%s\tgate\tGate outbound messaging until recipients are confirmed.\tgate\n' "$GATE_POLICY" \
  > "$FIX/workspace/orchestrator/policy-enforcement/$GATE_SID.policies.tsv"
GATE_PROMPT="$(jq -nc --arg sid "$GATE_SID" '{session_id:$sid,prompt:"Send a Slack message."}')"
run_hook UserPromptSubmit "$GATE_PROMPT" >/dev/null
GATE_SEND="$(jq -nc --arg sid "$GATE_SID" '{session_id:$sid,tool_name:"mcp__slack__send_message",tool_input:{message:"hello"}}')"
set +e
BLOCK="$(run_hook PreToolUse "$GATE_SEND")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "gate policy did not block when its required fact was absent"
GATE_BASH="$(jq -nc --arg sid "$GATE_SID" --arg cmd 'custom-mail send --to example' '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd}}')"
set +e
BLOCK="$(run_hook PreToolUse "$GATE_BASH")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "gate.bash prefix did not match outside the generic outbound detector"
pass "enforces gate tools, required facts, and freshness schema"
OVERRIDE_ANSWER="$(jq -nc --arg sid "$GATE_SID" '{session_id:$sid,tool_name:"AskUserQuestion",tool_input:{questions:[{header:"gate-override:gate-schema",question:"Allow this gate once?"}]},tool_response:{answers:[{answer:"Override once"}]}}')"
run_hook PostToolUse "$OVERRIDE_ANSWER" >/dev/null
run_hook PreToolUse "$GATE_SEND" >/dev/null || fail "a fresh allowed one-time override did not pass the gate"
set +e
BLOCK="$(run_hook PreToolUse "$GATE_SEND")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "gate override was reusable instead of one-time"
pass "consumes a fresh AskUserQuestion override exactly once"
GATE_FACT_DIR="$FIX/workspace/orchestrator/hook-state/gate-facts/$GATE_SID"
mkdir -p "$GATE_FACT_DIR"
jq -nc --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{fact:"recipients_confirmed",confirmed_at:$at,note:"fixture",source:"helper"}' \
  > "$GATE_FACT_DIR/recipients_confirmed.json"
run_hook PreToolUse "$GATE_SEND" >/dev/null || fail "fresh required fact did not pass the gate"
jq -nc '{fact:"recipients_confirmed",confirmed_at:"2000-01-01T00:00:00Z",note:"fixture",source:"helper"}' \
  > "$GATE_FACT_DIR/recipients_confirmed.json"
set +e
BLOCK="$(run_hook PreToolUse "$GATE_SEND")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "stale required fact passed the gate freshness check"
pass "enforces fresh and stale required gate facts"

BAD_GATE="$FIX/policies/bad-gate-schema.md"
cat > "$BAD_GATE" <<'EOF'
---
id: bad-gate-schema
enforcement: gate
gate:
  tools: [mcp__slack__send_message]
  requires: [recipients_confirmed]
  freshness: yesterday
  unknown: rejected
---
## Rule
Bad gate schema fixture.
EOF
BAD_GATE_SID="bad-gate-schema-session"
printf 'bad-gate-schema\tcore\t%s\tgate\tBad gate schema fixture.\tgate\n' "$BAD_GATE" \
  > "$FIX/workspace/orchestrator/policy-enforcement/$BAD_GATE_SID.policies.tsv"
BAD_GATE_SEND="$(jq -nc --arg sid "$BAD_GATE_SID" '{session_id:$sid,tool_name:"mcp__slack__send_message",tool_input:{message:"hello"}}')"
set +e
BLOCK="$(run_hook PreToolUse "$BAD_GATE_SEND")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "malformed gate schema did not fail closed"
printf '%s' "$BLOCK" | jq -e '.reason | contains("bad-gate-schema") and contains("invalid")' >/dev/null \
  || fail "malformed gate schema block did not identify the policy"
pass "fails closed on gate metadata rejected by the policy schema"

LOCK="$FIX/workspace/orchestrator/policy-enforcement/$SID.json.lock"
mkdir -p "$LOCK"
printf '2147483000\n' > "$LOCK/pid"
printf '1\n' > "$LOCK/time"
run_hook PostToolUse "$READ_BRIEF" >/dev/null || fail "stale state lock prevented receipt update"
[ ! -d "$LOCK" ] || fail "stale state lock was not reclaimed"
pass "reclaims an abandoned state lock"

UNRESOLVED="$(jq -nc '{session_id:"unresolved",prompt:"Use the attached brief and send a Slack broadcast."}')"
run_hook UserPromptSubmit "$UNRESOLVED" >/dev/null || fail "unresolved prompt setup failed"
UNRESOLVED_SEND="$(jq -nc '{session_id:"unresolved",tool_name:"mcp__slack__send_message",tool_input:{message:":chart_with_upwards_trend: update"}}')"
set +e
BLOCK="$(run_hook PreToolUse "$UNRESOLVED_SEND")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "unresolved declared attachment did not fail closed"
printf '%s' "$BLOCK" | jq -e '.reason | contains("declared-attachment-without-resolvable-path")' >/dev/null \
  || fail "unresolved attachment was not named"
pass "fails closed when an attached brief has no resolvable path"

echo "PASS (policy enforcement gate)"
