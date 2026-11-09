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
mkdir -p "$FIX/.claude/skills/security-review"
printf '# Security Review\n' > "$FIX/.claude/skills/security-review/SKILL.md"
printf '# Brief\n' > "$FIX/brief.md"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }
run_hook() {
  local event="$1" payload="$2" rc=0
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.claude/hooks/policy-enforcement-gate.sh" "$event" || rc=$?
  return "$rc"
}

# Force jq answer-row CRLF on every platform, including macOS CI. The
# first and middle rows must not carry the transport CR into persisted JSON.
CRLF_SHIM="$TMP/crlf-bin"
mkdir -p "$CRLF_SHIM"
export HQ_TEST_REAL_JQ="$(command -v jq)"
cat > "$CRLF_SHIM/jq" <<'CRLF_JQ'
#!/usr/bin/env bash
set -euo pipefail
force_crlf=0
for arg in "$@"; do
  case "$arg" in
    *'def gate_row('*|'.requiredSkills[]?'|'.briefs[]?'|'.requires[]') force_crlf=1 ;;
  esac
done
if [ "$force_crlf" = 1 ]; then
  "$HQ_TEST_REAL_JQ" "$@" | while IFS= read -r line; do
    printf '%s\r\n' "${line%$'\r'}"
  done
else
  exec "$HQ_TEST_REAL_JQ" "$@"
fi
CRLF_JQ
chmod +x "$CRLF_SHIM/jq"
CRLF_SID=crlf-answer-rows
printf '%s\n' '{}' > "$FIX/workspace/orchestrator/policy-enforcement/$CRLF_SID.json"
CRLF_INPUT="$(jq -nc --arg sid "$CRLF_SID" '{session_id:$sid,tool_name:"AskUserQuestion",tool_input:{questions:[{question:"Send it?",header:"gate-fact:sending_account_confirmed"},{question:"Recipients?",header:"gate-fact:recipients_confirmed"},{question:"Override?",header:"gate-override:p2"}]},tool_response:{answers:{"Send it?":"yes","Recipients?":"CONFIRMED","Override?":{label:"Allow once"}}}}')"
PATH="$CRLF_SHIM:$PATH" run_hook PostToolUse "$CRLF_INPUT" >/dev/null || fail "CRLF answer rows failed"
CRLF_STATE="$FIX/workspace/orchestrator/hook-state"
jq -e '.note == "yes"' "$CRLF_STATE/gate-facts/$CRLF_SID/sending_account_confirmed.json" >/dev/null || fail "first answer retained CR"
jq -e '.note == "CONFIRMED"' "$CRLF_STATE/gate-facts/$CRLF_SID/recipients_confirmed.json" >/dev/null || fail "middle answer retained CR"
jq -e '.answer == "Allow once"' "$CRLF_STATE/gate-overrides/$CRLF_SID/p2.json" >/dev/null || fail "last answer retained CR"
pass "CRLF answer rows preserve clean fact notes and override answers"

# Exercise CRLF receipt names and each Windows absolute path spelling.
receipt_case() {
  local skill_path="$1" brief_path="$2" payload read_path
  MSYS2_ARG_CONV_EXCL='*' jq -nc --arg brief "$brief_path" '{requiredSkills:["work-broadcast"],briefs:[$brief],receipts:{skills:[],briefs:[]}}' > "$FIX/workspace/orchestrator/policy-enforcement/crlf-receipts.json"
  for read_path in "$skill_path" "$brief_path"; do
    payload="$(MSYS2_ARG_CONV_EXCL='*' jq -nc --arg path "$read_path" '{session_id:"crlf-receipts",tool_name:"Read",tool_input:{file_path:$path},tool_response:{}}')"
    PATH="$CRLF_SHIM:$PATH" run_hook PostToolUse "$payload" >/dev/null || fail "CRLF receipt read failed"
  done
  cat "$FIX/workspace/orchestrator/policy-enforcement/crlf-receipts.json" | MSYS2_ARG_CONV_EXCL='*' jq -e --arg brief "$brief_path" '.receipts.skills == ["work-broadcast"] and .receipts.briefs == [$brief]' >/dev/null || fail "CRLF receipt names or absolute paths did not resolve"
}
receipt_case "$FIX/.claude/skills/work-broadcast/SKILL.md" "$FIX/brief.md"
if command -v cygpath >/dev/null 2>&1; then
  receipt_case "$(cygpath -m "$FIX/.claude/skills/work-broadcast/SKILL.md")" "$(cygpath -m "$FIX/brief.md")"
  receipt_case "$(cygpath -w "$FIX/.claude/skills/work-broadcast/SKILL.md")" "$(cygpath -w "$FIX/brief.md")"
  receipt_case "$(cygpath -u "$FIX/.claude/skills/work-broadcast/SKILL.md")" "$(cygpath -u "$FIX/brief.md")"
fi
pass "CRLF receipt names and absolute read paths resolve"

# Drive-shaped relative paths on Unix resolve against HQ, not cwd.
case "${OSTYPE:-}" in msys*|cygwin*|win32*) ;; *)
  mkdir -p "$FIX/C:" "$TMP/elsewhere/C:"
  printf '# HQ brief\n' > "$FIX/C:/brief.md"
  printf '# Wrong cwd brief\n' > "$TMP/elsewhere/C:/brief.md"
  printf '%s\n' '{"requiredSkills":[],"briefs":["C:/brief.md"],"receipts":{"skills":[],"briefs":[]}}' > "$FIX/workspace/orchestrator/policy-enforcement/drive-relative.json"
  payload="$(jq -nc --arg path "$FIX/C:/brief.md" '{session_id:"drive-relative",tool_name:"Read",tool_input:{file_path:$path},tool_response:{}}')"
  (cd "$TMP/elsewhere"; run_hook PostToolUse "$payload") >/dev/null || fail 'drive-shaped relative read failed'
  jq -e '.receipts.briefs == ["C:/brief.md"]' "$FIX/workspace/orchestrator/policy-enforcement/drive-relative.json" >/dev/null || fail 'drive-shaped path did not resolve against HQ root'
  pass 'Unix drive-shaped path resolves against HQ root when cwd differs'
;; esac

# Cover Windows forms even without an installed cygpath. The converter models
# only synthetic paths; classification and normalization remain production code.
(
  . "$ROOT/core/scripts/hook-lib.sh"
  for form in 'C:/fixture/brief.md' 'c:/fixture/brief.md' 'C:\fixture\brief.md' 'c:\fixture\brief.md'; do
    if HQ_LIB_WINSEP=0 hq_path_is_absolute "$form"; then fail 'drive path absolute on Unix'; fi
    HQ_LIB_WINSEP=1 hq_path_is_absolute "$form" || fail 'drive path relative on Windows'
  done
  HQ_LIB_WINSEP=1 hq_path_is_absolute '/c/fixture/brief.md' || fail 'MSYS drive path relative'
  PATH= builtin command -v cygpath >/dev/null && fail 'cygpath unexpectedly available'
  cygpath() {
    [ "$1" = -m ] || return 1
    case "$2" in C:/fixture/brief.md|c:/fixture/brief.md|/c/fixture/brief.md|/C/fixture/brief.md) printf '%s\n' 'C:/fixture/brief.md' ;; *) return 1 ;; esac
  }
  for form in 'C:/fixture/brief.md' 'c:/fixture/brief.md' 'C:\fixture\brief.md' '/c/fixture/brief.md' '/C/fixture/brief.md'; do
    actual="$(PATH= HQ_LIB_WINSEP=1 hq_canonical_path "$form")"
    [ "$actual" = 'C:/fixture/brief.md' ] || fail 'stubbed Windows converter path mismatch'
  done
)
pass 'Windows drive forms covered without installed cygpath'

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

# feedback_90ea6d44: "use HQ skill to rename this chat session" named no
# installed skill. Requiring "hq" left a receipt that could never be earned.
NO_SKILL_SID="no-such-skill"
NO_SKILL_PROMPT="$(jq -nc --arg sid "$NO_SKILL_SID" '{session_id:$sid,prompt:"use HQ skill to rename this chat session"}')"
run_hook UserPromptSubmit "$NO_SKILL_PROMPT" >/dev/null
jq -e '.requiredSkills == []' "$FIX/workspace/orchestrator/policy-enforcement/$NO_SKILL_SID.json" >/dev/null \
  || fail "prompt-named skill without a SKILL.md became a requirement: $(cat "$FIX/workspace/orchestrator/policy-enforcement/$NO_SKILL_SID.json")"
NO_SKILL_SEND="$(jq -nc --arg sid "$NO_SKILL_SID" '{session_id:$sid,tool_name:"mcp__slack__send_message",tool_input:{message:"hello"}}')"
run_hook PreToolUse "$NO_SKILL_SEND" >/dev/null \
  || fail "nonexistent prompt-named skill still blocked an outbound send"
pass "requires only prompt-named skills that are installed"

# feedback_90ea6d44: read-only MCP tools are not sends, even when a later word
# in the action is post/message/email. Use a session whose receipt is missing
# so any outbound classification would block.
READONLY_SID="readonly-mcp"
READONLY_PROMPT="$(jq -nc --arg sid "$READONLY_SID" '{session_id:$sid,prompt:"Use the security-review skill and summarize the newsletter."}')"
run_hook UserPromptSubmit "$READONLY_PROMPT" >/dev/null
jq -e '.requiredSkills == ["security-review"] and (.receipts.skills == [])' \
  "$FIX/workspace/orchestrator/policy-enforcement/$READONLY_SID.json" >/dev/null \
  || fail "read-only fixture did not declare an unmet skill requirement"
for tool in mcp__71ea2368-aaaa__get_post_content mcp__beehiiv__list_posts mcp__slack__search_messages \
            mcp__gmail__read_email mcp__slack__getPostPermalink mcp__superhuman__get_message; do
  READONLY_CALL="$(jq -nc --arg sid "$READONLY_SID" --arg tool "$tool" '{session_id:$sid,tool_name:$tool,tool_input:{post_id:"post_1"}}')"
  run_hook PreToolUse "$READONLY_CALL" >/dev/null || fail "read-only tool $tool was classified as an outbound send"
done
pass "does not classify read-only get_/list_/search_/read_ MCP tools as sends"
for tool in mcp__slack__send_message mcp__slack__slack_post_message mcp__beehiiv__create_post \
            mcp__gmail__reply_to_thread mcp__x__publish_post SendEmail \
            mcp__superhuman-mail__send_draft mcp__mail__post_draft; do
  SEND_CALL="$(jq -nc --arg sid "$READONLY_SID" --arg tool "$tool" '{session_id:$sid,tool_name:$tool,tool_input:{message:"hi"}}')"
  set +e
  BLOCK="$(run_hook PreToolUse "$SEND_CALL")"; RC=$?
  set -e
  [ "$RC" -eq 2 ] || fail "outbound tool $tool was not gated (rc=$RC)"
  printf '%s' "$BLOCK" | jq -e '.reason | contains("Missing skills: security-review")' >/dev/null \
    || fail "outbound tool $tool block reason incomplete: $BLOCK"
done
pass "still gates send/post/reply/publish MCP tools"
# feedback_e6f00358: a draft stages text for a person to send; it is not a send.
for tool in mcp__slack__slack_send_message_draft mcp__superhuman-mail__create_or_update_draft \
            mcp__gmail__create_draft mcp__gmail__draft_email mcp__slack__sendMessageDraft; do
  DRAFT_CALL="$(jq -nc --arg sid "$READONLY_SID" --arg tool "$tool" '{session_id:$sid,tool_name:$tool,tool_input:{message:"hi"}}')"
  run_hook PreToolUse "$DRAFT_CALL" >/dev/null || fail "draft tool $tool was classified as an outbound send"
done
pass "does not classify draft tools as sends"

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

# feedback_e6f00358: a read-only grep for "hq dm" is a read, not a send.
for cmd in 'grep -n "hq dm" .claude/skills/dm/SKILL.md' \
           "rg 'hq dm|chat.postMessage' .claude/skills" \
           'cat .claude/skills/dm/SKILL.md | grep -n "hq dm send"'; do
  GREP_DM="$(jq -nc --arg sid "$SID" --arg cmd "$cmd" '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd}}')"
  run_hook PreToolUse "$GREP_DM" >/dev/null || fail "read-only command was treated as outbound: $cmd"
done
pass "does not treat hq dm inside a read-only grep or cat as outbound"
for cmd in 'hq dm channel hq-dev --limit 60' 'hq dm inbox --unread' 'hq dm thread stefan@example.com --no-ack' \
           'hq dm history "#launch" --mark-read' 'hq dm read someone@example.com'; do
  READ_DM="$(jq -nc --arg sid "$SID" --arg cmd "$cmd" '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd}}')"
  run_hook PreToolUse "$READ_DM" >/dev/null || fail "read-only hq dm subcommand was treated as outbound: $cmd"
done
pass "does not treat read-only hq dm inbox|thread|channel|history as outbound"
for cmd in 'hq dm send --to someone' 'cd /tmp && hq dm send --to someone' \
           'grep -n x f.md; hq dm send --to someone' 'grep -l "hq dm send" f.md | sh' \
           'grep "$(hq dm send --to someone)" f.md' 'rg --pre "hq dm send" x .' \
           'curl https://slack.com/api/chat.postMessage'; do
  REAL_DM="$(jq -nc --arg sid "$SID" --arg cmd "$cmd" '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd}}')"
  set +e
  run_hook PreToolUse "$REAL_DM" >/dev/null; RC=$?
  set -e
  [ "$RC" -eq 2 ] || fail "outbound command was not gated (rc=$RC): $cmd"
done
pass "still gates a running hq dm send, including through a shell or substitution"

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
PATH="$CRLF_SHIM:$PATH" run_hook PreToolUse "$GATE_SEND" >/dev/null || fail "fresh required fact did not pass the CRLF gate"
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

# feedback_e6f00358: file names in pasted Slack text are mentions, not
# attachments, even when "attached ... file" appears elsewhere in the prompt.
# The brief named in the attachment clause is still required.
mkdir -p "$FIX/docs"
printf '# Notes\n' > "$FIX/notes.md"
printf '# Spec\n' > "$FIX/docs/spec.md"
MENTION_SID="mention-only"
MENTION_PROMPT="$(jq -nc --arg sid "$MENTION_SID" --arg p $'Draft a Slack reply using the attached brief brief.md.\n\nPasted from Slack:\nMike: see CLAUDE.md and voice.md, notes.md has the rest.\nAna: I attached the file yesterday.' '{session_id:$sid,prompt:$p}')"
run_hook UserPromptSubmit "$MENTION_PROMPT" >/dev/null || fail "mention prompt setup failed"
MENTION_STATE="$FIX/workspace/orchestrator/policy-enforcement/$MENTION_SID.json"
jq -e '.briefs == ["brief.md"]' "$MENTION_STATE" >/dev/null \
  || fail "file names outside the attachment clause became required briefs: $(jq -c .briefs "$MENTION_STATE")"
MENTION_SEND="$(jq -nc --arg sid "$MENTION_SID" '{session_id:$sid,tool_name:"mcp__slack__send_message",tool_input:{message:"reply"}}')"
set +e
BLOCK="$(run_hook PreToolUse "$MENTION_SEND")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "attached brief did not require its receipt"
printf '%s' "$BLOCK" | jq -e '.reason | contains("Missing briefs: brief.md.")' >/dev/null \
  || fail "attached-brief block named mentioned files: $BLOCK"
run_hook PostToolUse "$(printf '%s' "$READ_BRIEF" | jq --arg sid "$MENTION_SID" '.session_id=$sid')" >/dev/null
run_hook PreToolUse "$MENTION_SEND" >/dev/null \
  || fail "send stayed blocked on mentioned-only files after the attached brief was read"
pass "requires only files named in the attachment clause, not pasted mentions"

LIST_SID="attached-list"
LIST_PROMPT="$(jq -nc --arg sid "$LIST_SID" --arg p $'Send the update. Use the attached brief files:\n- brief.md\n- docs/spec.md\n\nUnrelated: notes.md' '{session_id:$sid,prompt:$p}')"
run_hook UserPromptSubmit "$LIST_PROMPT" >/dev/null || fail "list prompt setup failed"
jq -e '.briefs == ["brief.md","docs/spec.md"]' "$FIX/workspace/orchestrator/policy-enforcement/$LIST_SID.json" >/dev/null \
  || fail "attached list was not declared exactly: $(jq -c .briefs "$FIX/workspace/orchestrator/policy-enforcement/$LIST_SID.json")"
pass "declares every path listed under an attachment clause that ends with a colon"

# A long session's matched-policy list grows past a thousand rows, and the gate
# rereads it on every tool call. Collect required-skill/required-brief values in
# one pass instead of starting programs per listed policy.
LONG_SID="long-session-policy-list"
LONG_TSV="$FIX/workspace/orchestrator/policy-enforcement/$LONG_SID.policies.tsv"
mkdir -p "$FIX/policies/long"
: > "$LONG_TSV"
for i in $(seq 1 300); do
  printf -- '---\nid: plain-%s\nenforcement: soft\n---\n## Rule\nPlain policy %s.\n' "$i" "$i" > "$FIX/policies/long/plain-$i.md"
  printf 'plain-%s\tcore\t%s\tsoft\tPlain policy %s.\n' "$i" "$FIX/policies/long/plain-$i.md" "$i" >> "$LONG_TSV"
done
printf -- '---\nid: needs-skills\nrequired-skill:  alpha-skill , beta-skill,alpha-skill\n---\n' > "$FIX/policies/long/needs-skills.md"
printf -- '---\nid: needs-brief\nrequired-brief:   docs/long-brief.md  \n---\n' > "$FIX/policies/long/needs-brief.md"
printf -- '---\nid: also-skill\nrequired-skill: beta-skill, gamma-skill\n---\n' > "$FIX/policies/long/also-skill.md"
{
  printf 'needs-skills\tcore\t%s\tsoft\tx\n' "$FIX/policies/long/needs-skills.md"
  printf 'missing-file\tcore\t%s\tsoft\tx\n' "$FIX/policies/long/does-not-exist.md"
  printf 'dir-path\tcore\t%s\tsoft\tx\n' "$FIX/policies/long"
  printf 'needs-brief\tcore\t%s\tsoft\tx\n' "$FIX/policies/long/needs-brief.md"
  printf 'also-skill\tcore\t%s\tsoft\tx\n' "$FIX/policies/long/also-skill.md"
} >> "$LONG_TSV"
SHIM="$TMP/shim"
mkdir -p "$SHIM"
for tool in sed tr; do
  real="$(command -v "$tool")"
  printf '#!/bin/sh\necho %s >> "%s/calls"\nexec "%s" "$@"\n' "$tool" "$SHIM" "$real" > "$SHIM/$tool"
  chmod +x "$SHIM/$tool"
done
LONG_READ="$(jq -nc --arg sid "$LONG_SID" '{session_id:$sid,tool_name:"Read",tool_input:{file_path:"/dev/null"}}')"
printf '%s' "$LONG_READ" | PATH="$SHIM:$PATH" CLAUDE_PROJECT_DIR="$FIX" \
  bash "$FIX/.claude/hooks/policy-enforcement-gate.sh" PreToolUse >/dev/null \
  || fail "PreToolUse failed on a long matched-policy list"
LONG_STATE="$FIX/workspace/orchestrator/policy-enforcement/$LONG_SID.json"
jq -e '.requiredSkills == ["alpha-skill","beta-skill","gamma-skill"] and .briefs == ["docs/long-brief.md"]' "$LONG_STATE" >/dev/null \
  || fail "requirements from a long policy list were not collected: $(cat "$LONG_STATE")"
CALLS=0
[ ! -f "$SHIM/calls" ] || CALLS="$(wc -l < "$SHIM/calls" | tr -d ' ')"
[ "$CALLS" -le 2 ] || fail "PreToolUse started $CALLS sed/tr processes for a 305-row policy list"
pass "collects policy requirements from a long list without per-policy processes"

# Saved-draft send. draft_approved comes only from a host-delivered user
# answer (AskUserQuestion or Codex request_user_input) to a gate-fact question.
# No prompt text approves a send, whatever it says.
install_draft_gate() {
  local sid="$1" fresh="${2:-}" pol fresh_line=""
  [ -z "$fresh" ] || fresh_line="  freshness: $fresh"
  pol="$FIX/policies/draft-gate-$sid.md"
  cat > "$pol" <<EOF
---
id: draft-gate-$sid
enforcement: gate
gate:
  tools: [mcp__gmail__send_draft, mcp__mail__post_draft]
  requires: [draft_approved]
$fresh_line
---
## Rule
Deliver a saved draft only after draft_approved.
EOF
  printf 'draft-gate-%s\tcore\t%s\tgate\tDeliver a saved draft only after draft_approved.\tgate\n' "$sid" "$pol" \
    > "$FIX/workspace/orchestrator/policy-enforcement/$sid.policies.tsv"
}
draft_prompt() {
  local sid="$1" prompt="$2" payload
  payload="$(jq -nc --arg sid "$sid" --arg prompt "$prompt" '{session_id:$sid,prompt:$prompt}')"
  run_hook UserPromptSubmit "$payload" >/dev/null || fail "draft-gate prompt declaration failed for $sid"
}
draft_call() {
  jq -nc --arg sid "$1" --arg tool "$2" '{session_id:$sid,tool_name:$tool,tool_input:{message:"hello"}}'
}

DRAFT_ONLY_SID="draft-only-send"
install_draft_gate "$DRAFT_ONLY_SID"
draft_prompt "$DRAFT_ONLY_SID" "Save a draft only. Do not send."
set +e
BLOCK="$(run_hook PreToolUse "$(draft_call "$DRAFT_ONLY_SID" mcp__gmail__send_draft)")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "draft-only prompt allowed gmail send_draft (rc=$RC): $BLOCK"
printf '%s' "$BLOCK" | jq -e '.reason | contains("draft_approved")' >/dev/null \
  || fail "draft-only block did not name draft_approved: $BLOCK"
pass "draft-only does not allow gmail send_draft"
run_hook PreToolUse "$(draft_call "$DRAFT_ONLY_SID" mcp__gmail__create_draft)" >/dev/null \
  || fail "draft-only prompt blocked gmail create_draft"
pass "draft-only does not block gmail create_draft"

SLACK_SID="unrelated-slack-send"
install_draft_gate "$SLACK_SID"
draft_prompt "$SLACK_SID" "Send a Slack message about the roadmap."
set +e
BLOCK="$(run_hook PreToolUse "$(draft_call "$SLACK_SID" mcp__gmail__send_draft)")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "unrelated send prompt allowed gmail send_draft (rc=$RC): $BLOCK"
printf '%s' "$BLOCK" | jq -e '.reason | contains("draft_approved")' >/dev/null \
  || fail "unrelated send block did not name draft_approved: $BLOCK"
pass "unrelated send does not allow gmail send_draft"

# Prompt text never approves a send. Each of these once matched the
# "send it" / "send the draft" phrase check and skipped the freshness gate.
i=0
while IFS= read -r prompt; do
  [ -n "$prompt" ] || continue
  i=$((i + 1))
  PSID="prompt-not-approval-$i"
  install_draft_gate "$PSID"
  draft_prompt "$PSID" "$prompt"
  for tool in mcp__gmail__send_draft mcp__mail__post_draft; do
    set +e
    BLOCK="$(run_hook PreToolUse "$(draft_call "$PSID" "$tool")")"; RC=$?
    set -e
    [ "$RC" -eq 2 ] || fail "prompt '$prompt' allowed $tool (rc=$RC): $BLOCK"
    printf '%s' "$BLOCK" | jq -e '.reason | contains("draft_approved")' >/dev/null \
      || fail "prompt '$prompt' block did not name draft_approved: $BLOCK"
  done
  [ ! -e "$FIX/workspace/orchestrator/hook-state/gate-facts/$PSID/draft_approved.json" ] \
    || fail "prompt '$prompt' wrote draft_approved"
  pass "prompt does not approve a saved-draft send: $prompt"
done <<'PROMPTS'
Write a reply to Bob and send it
Should I send it?
Show me the draft before you send it
Don’t send it yet
Never send it without asking me
send it later
I reviewed the saved draft. Send it.
Send the draft.
Go ahead and send the draft
PROMPTS

CODEX_SID="codex-draft-approved"
install_draft_gate "$CODEX_SID"
draft_prompt "$CODEX_SID" "Reviewing the draft."
set +e
BLOCK="$(run_hook PreToolUse "$(draft_call "$CODEX_SID" mcp__gmail__send_draft)")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "a non-approval prompt allowed gmail send_draft before the gate answer (rc=$RC)"
CODEX_ANSWER="$(jq -nc --arg sid "$CODEX_SID" '{session_id:$sid,tool_name:"request_user_input",tool_input:{questions:[{id:"draft-send",header:"gate-fact:draft_approved",question:"Approve sending the saved draft?"}]},tool_response:{answers:{"draft-send":{answers:["approved"]}}}}')"
run_hook PostToolUse "$CODEX_ANSWER" >/dev/null || fail "request_user_input approval was rejected"
CODEX_FACT="$FIX/workspace/orchestrator/hook-state/gate-facts/$CODEX_SID/draft_approved.json"
[ -f "$CODEX_FACT" ] || fail "request_user_input approval did not write draft_approved"
[ "$(jq -r '.fact' "$CODEX_FACT")" = draft_approved ] || fail "request_user_input fact field mismatch: $(cat "$CODEX_FACT")"
[ "$(jq -r '.source' "$CODEX_FACT")" = askuserquestion ] || fail "request_user_input source mismatch: $(cat "$CODEX_FACT")"
[ "$(jq -r '.note' "$CODEX_FACT")" = approved ] || fail "request_user_input note mismatch: $(cat "$CODEX_FACT")"
run_hook PreToolUse "$(draft_call "$CODEX_SID" mcp__gmail__send_draft)" >/dev/null \
  || fail "request_user_input approval did not allow gmail send_draft"
pass "request_user_input approval records draft_approved and allows gmail send_draft"

REFUSAL_SID="codex-draft-refused"
install_draft_gate "$REFUSAL_SID"
draft_prompt "$REFUSAL_SID" "Reviewing the draft."
REFUSAL_ANSWER="$(jq -nc --arg sid "$REFUSAL_SID" '{session_id:$sid,tool_name:"request_user_input",tool_input:{questions:[{id:"draft-send",header:"gate-fact:draft_approved",question:"Approve sending the saved draft?"}]},tool_response:{answers:{"draft-send":{answers:["do not send"]}}}}')"
run_hook PostToolUse "$REFUSAL_ANSWER" >/dev/null || fail "request_user_input refusal was rejected"
REFUSAL_FACT="$FIX/workspace/orchestrator/hook-state/gate-facts/$REFUSAL_SID/draft_approved.json"
[ ! -e "$REFUSAL_FACT" ] || fail "request_user_input refusal wrote draft_approved"
set +e
BLOCK="$(run_hook PreToolUse "$(draft_call "$REFUSAL_SID" mcp__gmail__send_draft)")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "request_user_input refusal allowed gmail send_draft (rc=$RC): $BLOCK"
pass "request_user_input refusal does not record draft_approved"

PROMOTE_SID="askuser-draft-promote"
install_draft_gate "$PROMOTE_SID"
draft_prompt "$PROMOTE_SID" "Reviewing the draft."
PROMOTE_ANSWER="$(jq -nc --arg sid "$PROMOTE_SID" '{session_id:$sid,tool_name:"AskUserQuestion",tool_input:{questions:[{header:"gate-fact:draft_approved",question:"Approve sending the saved draft?"}]},tool_response:{answers:[{answer:"Approved"}]}}')"
run_hook PostToolUse "$PROMOTE_ANSWER" >/dev/null || fail "AskUserQuestion approval was rejected"
PROMOTE_FACT="$FIX/workspace/orchestrator/hook-state/gate-facts/$PROMOTE_SID/draft_approved.json"
PROMOTE_PROOF="$FIX/workspace/orchestrator/hook-state/gate-facts/$PROMOTE_SID/proofs/draft_approved.json"
[ -f "$PROMOTE_FACT" ] || fail "AskUserQuestion approval did not write draft_approved without hq-gate-fact.sh"
[ ! -e "$PROMOTE_PROOF" ] || fail "AskUserQuestion approval left the proof behind after writing the fact"
[ "$(jq -r '.fact' "$PROMOTE_FACT")" = draft_approved ] || fail "promoted fact field mismatch: $(cat "$PROMOTE_FACT")"
[ "$(jq -r '.source' "$PROMOTE_FACT")" = askuserquestion ] || fail "promoted source mismatch: $(cat "$PROMOTE_FACT")"
[ "$(jq -r '.note' "$PROMOTE_FACT")" = Approved ] || fail "promoted note mismatch: $(cat "$PROMOTE_FACT")"
[ "$(jq -r '.confirmed_at | type' "$PROMOTE_FACT")" = string ] || fail "promoted fact has no timestamp"
run_hook PreToolUse "$(draft_call "$PROMOTE_SID" mcp__gmail__send_draft)" >/dev/null \
  || fail "promoted draft_approved did not allow gmail send_draft"
pass "AskUserQuestion approval writes draft_approved without hq-gate-fact.sh"

OBJ_SID="askuser-draft-object-answer"
install_draft_gate "$OBJ_SID"
draft_prompt "$OBJ_SID" "Reviewing the draft."
OBJ_ANSWER="$(jq -nc --arg sid "$OBJ_SID" '{session_id:$sid,tool_name:"AskUserQuestion",tool_input:{questions:[{header:"gate-fact:draft_approved",question:"Approve sending the saved draft?"}]},tool_response:{answers:{"Approve sending the saved draft?":"Approved"}}}')"
run_hook PostToolUse "$OBJ_ANSWER" >/dev/null || fail "AskUserQuestion object answer was rejected"
[ -f "$FIX/workspace/orchestrator/hook-state/gate-facts/$OBJ_SID/draft_approved.json" ] \
  || fail "AskUserQuestion object answer keyed by question text did not write draft_approved"
run_hook PreToolUse "$(draft_call "$OBJ_SID" mcp__gmail__send_draft)" >/dev/null \
  || fail "object-shaped AskUserQuestion approval did not allow gmail send_draft"
pass "AskUserQuestion answer keyed by question text records draft_approved"

NOHDR_SID="askuser-other-header"
install_draft_gate "$NOHDR_SID"
draft_prompt "$NOHDR_SID" "Reviewing the draft."
NOHDR_ANSWER="$(jq -nc --arg sid "$NOHDR_SID" '{session_id:$sid,tool_name:"AskUserQuestion",tool_input:{questions:[{header:"Next step",question:"Approve sending the saved draft?"}]},tool_response:{answers:{"Approve sending the saved draft?":"Approved"}}}')"
run_hook PostToolUse "$NOHDR_ANSWER" >/dev/null || fail "AskUserQuestion non-gate answer was rejected"
[ ! -e "$FIX/workspace/orchestrator/hook-state/gate-facts/$NOHDR_SID/draft_approved.json" ] \
  || fail "an answer to a non-gate question wrote draft_approved"
pass "an answer to a non-gate question does not record draft_approved"

# Each question reads only its own answer key: the question id for Codex
# request_user_input, the question text for Claude AskUserQuestion. A second
# question whose key equals the first question's header must not lend its answer.
assert_no_draft_fact() {
  local sid="$1" label="$2" rc
  [ ! -e "$FIX/workspace/orchestrator/hook-state/gate-facts/$sid/draft_approved.json" ] \
    || fail "$label minted draft_approved"
  set +e
  BLOCK="$(run_hook PreToolUse "$(draft_call "$sid" mcp__gmail__send_draft)")"; rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "$label allowed gmail send_draft (rc=$rc)"
}

COLID_SID="codex-colliding-id"
install_draft_gate "$COLID_SID"
draft_prompt "$COLID_SID" "Reviewing the draft."
COLID_ANSWER="$(jq -nc --arg sid "$COLID_SID" '{session_id:$sid,tool_name:"request_user_input",tool_input:{questions:[{id:"send",header:"gate-fact:draft_approved",question:"Send it?"},{id:"gate-fact:draft_approved",header:"Pick",question:"Tabs or spaces?"}]},tool_response:{answers:{"send":{answers:["Do not send"]},"gate-fact:draft_approved":{answers:["yes"]}}}}')"
run_hook PostToolUse "$COLID_ANSWER" >/dev/null || fail "colliding-id answer was rejected"
assert_no_draft_fact "$COLID_SID" "declined question next to a colliding question id"
pass "a declined question does not read another question's id-keyed answer"

COLTXT_SID="claude-colliding-question-text"
install_draft_gate "$COLTXT_SID"
draft_prompt "$COLTXT_SID" "Reviewing the draft."
COLTXT_ANSWER="$(jq -nc --arg sid "$COLTXT_SID" '{session_id:$sid,tool_name:"AskUserQuestion",tool_input:{questions:[{header:"gate-fact:draft_approved",question:"Send it?"},{header:"Pick",question:"gate-fact:draft_approved"}]},tool_response:{answers:{"Send it?":"Do not send","gate-fact:draft_approved":"yes"}}}')"
run_hook PostToolUse "$COLTXT_ANSWER" >/dev/null || fail "colliding-question-text answer was rejected"
assert_no_draft_fact "$COLTXT_SID" "declined question next to colliding question text"
pass "a declined question does not read another question's text-keyed answer"

HDRKEY_SID="answer-keyed-by-header"
install_draft_gate "$HDRKEY_SID"
draft_prompt "$HDRKEY_SID" "Reviewing the draft."
HDRKEY_ANSWER="$(jq -nc --arg sid "$HDRKEY_SID" '{session_id:$sid,tool_name:"AskUserQuestion",tool_input:{questions:[{header:"gate-fact:draft_approved",question:"Send it?"}]},tool_response:{answers:{"gate-fact:draft_approved":"yes"}}}')"
run_hook PostToolUse "$HDRKEY_ANSWER" >/dev/null || fail "header-keyed answer was rejected"
assert_no_draft_fact "$HDRKEY_SID" "an answer keyed only by the header"
pass "an answer keyed by the header is not a question's answer"

AMBIG_SID="ambiguous-answer-key"
install_draft_gate "$AMBIG_SID"
draft_prompt "$AMBIG_SID" "Reviewing the draft."
AMBIG_ANSWER="$(jq -nc --arg sid "$AMBIG_SID" '{session_id:$sid,tool_name:"request_user_input",tool_input:{questions:[{id:"draft",header:"gate-fact:draft_approved",question:"Send it?"},{id:"draft",header:"Pick",question:"Tabs or spaces?"}]},tool_response:{answers:{"draft":{answers:["yes"]}}}}')"
run_hook PostToolUse "$AMBIG_ANSWER" >/dev/null || fail "ambiguous-key answer was rejected"
assert_no_draft_fact "$AMBIG_SID" "two questions sharing one answer key"
pass "two questions sharing an answer key mint nothing"

# The answer key depends on the tool. Claude AskUserQuestion keys answers by
# question text and ignores any id; Codex request_user_input keys them by id
# and ignores question text. A declined question must not read an answer that
# another question's id (Claude) or text (Codex) points at.
CLAUDEID_SID="claude-id-collides-with-text"
install_draft_gate "$CLAUDEID_SID"
draft_prompt "$CLAUDEID_SID" "Reviewing the draft."
CLAUDEID_ANSWER="$(jq -nc --arg sid "$CLAUDEID_SID" '{session_id:$sid,tool_name:"AskUserQuestion",tool_input:{questions:[{id:"Lunch today?",header:"gate-fact:draft_approved",question:"Send the draft to Bob?"},{id:"zz",header:"Pick",question:"Lunch today?"}]},tool_response:{answers:{"Send the draft to Bob?":"Do not send","Lunch today?":"yes"}}}')"
run_hook PostToolUse "$CLAUDEID_ANSWER" >/dev/null || fail "AskUserQuestion id-collision answer was rejected"
assert_no_draft_fact "$CLAUDEID_SID" "AskUserQuestion declined question whose id equals another question's text"
pass "AskUserQuestion ignores question ids when choosing an answer key"

CODEXTXT_SID="codex-text-collides-with-id"
install_draft_gate "$CODEXTXT_SID"
draft_prompt "$CODEXTXT_SID" "Reviewing the draft."
CODEXTXT_ANSWER="$(jq -nc --arg sid "$CODEXTXT_SID" '{session_id:$sid,tool_name:"request_user_input",tool_input:{questions:[{id:"send",header:"gate-fact:draft_approved",question:"lunch"},{id:"lunch",header:"Pick",question:"Tabs or spaces?"}]},tool_response:{answers:{"send":{answers:["Do not send"]},"lunch":{answers:["yes"]}}}}')"
run_hook PostToolUse "$CODEXTXT_ANSWER" >/dev/null || fail "request_user_input text-collision answer was rejected"
assert_no_draft_fact "$CODEXTXT_SID" "request_user_input declined question whose text equals another question's id"
pass "request_user_input ignores question text when choosing an answer key"

CODEXTXT2_SID="codex-text-keyed-answer"
install_draft_gate "$CODEXTXT2_SID"
draft_prompt "$CODEXTXT2_SID" "Reviewing the draft."
CODEXTXT2_ANSWER="$(jq -nc --arg sid "$CODEXTXT2_SID" '{session_id:$sid,tool_name:"request_user_input",tool_input:{questions:[{id:"send",header:"gate-fact:draft_approved",question:"Send it?"}]},tool_response:{answers:{"Send it?":{answers:["yes"]}}}}')"
run_hook PostToolUse "$CODEXTXT2_ANSWER" >/dev/null || fail "request_user_input text-keyed answer was rejected"
assert_no_draft_fact "$CODEXTXT2_SID" "request_user_input answer keyed by question text"
pass "request_user_input answer keyed by question text is not its answer"

CODEXNOID_SID="codex-no-id-text-keyed"
install_draft_gate "$CODEXNOID_SID"
draft_prompt "$CODEXNOID_SID" "Reviewing the draft."
CODEXNOID_ANSWER="$(jq -nc --arg sid "$CODEXNOID_SID" '{session_id:$sid,tool_name:"request_user_input",tool_input:{questions:[{header:"gate-fact:draft_approved",question:"Send it?"}]},tool_response:{answers:{"Send it?":{answers:["yes"]}}}}')"
run_hook PostToolUse "$CODEXNOID_ANSWER" >/dev/null || fail "request_user_input answer without an id was rejected"
assert_no_draft_fact "$CODEXNOID_SID" "request_user_input question without an id read by its text"
pass "request_user_input question without an id has no answer key"

# One approval yields one fact. After the fact goes stale, hq-gate-fact.sh
# confirm must not mint a fresh one from the same approval.
cp -p "$ROOT/core/scripts/hq-gate-fact.sh" "$FIX/core/scripts/hq-gate-fact.sh"
ONCE_SID="one-approval-one-fact"
install_draft_gate "$ONCE_SID" 30
draft_prompt "$ONCE_SID" "Reviewing the draft."
ONCE_ANSWER="$(jq -nc --arg sid "$ONCE_SID" '{session_id:$sid,tool_name:"AskUserQuestion",tool_input:{questions:[{header:"gate-fact:draft_approved",question:"Approve sending the saved draft?"}]},tool_response:{answers:{"Approve sending the saved draft?":"Approved"}}}')"
run_hook PostToolUse "$ONCE_ANSWER" >/dev/null || fail "approval was rejected"
run_hook PreToolUse "$(draft_call "$ONCE_SID" mcp__gmail__send_draft)" >/dev/null \
  || fail "a fresh approval did not allow gmail send_draft"
ONCE_FACT="$FIX/workspace/orchestrator/hook-state/gate-facts/$ONCE_SID/draft_approved.json"
jq '.confirmed_at = "2000-01-01T00:00:00Z"' "$ONCE_FACT" > "$ONCE_FACT.tmp" && mv "$ONCE_FACT.tmp" "$ONCE_FACT"
set +e
BLOCK="$(run_hook PreToolUse "$(draft_call "$ONCE_SID" mcp__gmail__send_draft)")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "a stale approval allowed gmail send_draft (rc=$RC)"
set +e
HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" HQ_SESSION_ID="$ONCE_SID" bash "$FIX/core/scripts/hq-gate-fact.sh" confirm draft_approved >/dev/null 2>&1
BLOCK="$(run_hook PreToolUse "$(draft_call "$ONCE_SID" mcp__gmail__send_draft)")"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "hq-gate-fact.sh confirm re-minted draft_approved from a used approval (rc=$RC)"
pass "one approval does not yield a second, fresh draft_approved"

# Outbound delivery scan on a long list (#1744). Rows are checked in list
# order, the first delivery-*-regex line of each file wins, rows without a
# readable file are skipped, and the scan starts no sed or head per row.
OUT_SID="long-session-outbound"
OUT_TSV="$FIX/workspace/orchestrator/policy-enforcement/$OUT_SID.policies.tsv"
grep -v -e '^needs-' -e '^also-skill' "$LONG_TSV" > "$OUT_TSV"
printf -- '---\nid: first-forbid\ndelivery-forbid-regex: \t SECRET_A\ndelivery-forbid-regex: NEVER_USED\n---\n' > "$FIX/policies/long/first-forbid.md"
printf -- '---\nid: needs-tag\ndelivery-require-regex: ^TAG\n---\nbody text delivery-forbid-regex: not-at-line-start\n' > "$FIX/policies/long/needs-tag.md"
printf -- '---\nid: second-forbid\ndelivery-forbid-regex: SECRET_B\n---\n' > "$FIX/policies/long/second-forbid.md"
printf -- '---\nid: empty-key\ndelivery-forbid-regex:\n---\n' > "$FIX/policies/long/empty-key.md"
{
  printf 'empty-key\tcore\t%s\tsoft\tx\n' "$FIX/policies/long/empty-key.md"
  printf 'first-forbid\tcore\t%s\tsoft\tx\n' "$FIX/policies/long/first-forbid.md"
  printf 'needs-tag\tcore\t%s\tsoft\tx\n' "$FIX/policies/long/needs-tag.md"
  printf 'second-forbid\tcore\t%s\tsoft\tx\n' "$FIX/policies/long/second-forbid.md"
  printf 'first-forbid-again\tcore\t%s\tsoft\tx\n' "$FIX/policies/long/first-forbid.md"
} >> "$OUT_TSV"
out_send() { jq -nc --arg sid "$OUT_SID" --arg m "$1" '{session_id:$sid,tool_name:"SendMessage",tool_input:{message:$m}}'; }
out_expect() { # <message> <rc> <reason-or-empty>
  local out rc=0
  out="$(out_send "$1" | CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.claude/hooks/policy-enforcement-gate.sh" PreToolUse)" || rc=$?
  [ "$rc" -eq "$2" ] || fail "outbound '$1' exit $rc, expected $2: $out"
  if [ -n "$3" ]; then
    printf '%s' "$out" | jq -e --arg r "$3" '.reason == $r' >/dev/null || fail "outbound '$1' reason: $out"
  else
    [ -z "$out" ] || fail "outbound '$1' printed output: $out"
  fi
}
out_expect "TAG hello" 0 ""
out_expect "TAG has SECRET_A" 2 "POLICY ENFORCEMENT BLOCK: outbound content violates deterministic gate first-forbid (forbidden pattern)."
out_expect "TAG says NEVER_USED" 0 ""
out_expect "no tag here" 2 "POLICY ENFORCEMENT BLOCK: outbound content violates deterministic gate needs-tag (required pattern missing)."
out_expect "TAG with SECRET_B" 2 "POLICY ENFORCEMENT BLOCK: outbound content violates deterministic gate second-forbid (forbidden pattern)."
out_expect "SECRET_B without tag" 2 "POLICY ENFORCEMENT BLOCK: outbound content violates deterministic gate needs-tag (required pattern missing)."
out_expect "" 2 "POLICY ENFORCEMENT BLOCK: deterministic delivery gate first-forbid cannot inspect this outbound body. Supply content in a structured tool field or literal MESSAGE/BODY/TEXT shell assignment."
rm -f "$SHIM/calls"
for tool in head grep; do
  real="$(command -v "$tool")"
  printf '#!/bin/sh\necho %s >> "%s/calls"\nexec "%s" "$@"\n' "$tool" "$SHIM" "$real" > "$SHIM/$tool"
  chmod +x "$SHIM/$tool"
done
out_send "TAG hello" | PATH="$SHIM:$PATH" CLAUDE_PROJECT_DIR="$FIX" \
  bash "$FIX/.claude/hooks/policy-enforcement-gate.sh" PreToolUse >/dev/null \
  || fail "outbound send blocked under the process counter"
CALLS=0
[ ! -f "$SHIM/calls" ] || CALLS="$(wc -l < "$SHIM/calls" | tr -d ' ')"
# One sed in tool_is_outbound plus two grep checks per regex-bearing row
# (3 rows with 4 regexes here): at most 1 + 8.
[ "$CALLS" -le 9 ] || fail "outbound scan started $CALLS sed/head/grep/tr processes for a 307-row policy list"
pass "scans outbound content against a long list in list order without per-policy processes"

echo "PASS (policy enforcement gate)"
