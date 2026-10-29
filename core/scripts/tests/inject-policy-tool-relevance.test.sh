#!/usr/bin/env bash
# hq-core: public
# inject-policy-tool-relevance.test.sh
#
# Regression contract for feedback_9eda6433 (duplicate feedback_ff1c11af):
# per-tool-call policy reminders were mostly rules unrelated to the action.
#   [1] a HARD `inject: always` rule prints its full text at most once per
#       session; a later turn names it only in the "Already shown" footer.
#   [2] on a tool event, a rule whose trigger does not touch the action (an
#       unconditional `when: always`, or a SessionStart-only rule matched on a
#       generic word) is not printed on the tool call; it stays in the
#       enforcement set and is delivered on the next prompt instead. A
#       SessionStart-only rule whose trigger names a subject in the command
#       prints the first time it matches, even with no prompt event (owner
#       decision on #1688), and is not printed again.
#   [3] a HARD rule whose trigger matches the command is still injected on
#       the tool event, and a tool-only unconditional rule still fires.
# HOOK (or HQ_TEST_INJECT_POLICY_HOOK) points the run at another copy of the
# hook, e.g. main's, to show these cases fail there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${HOOK:-${HQ_TEST_INJECT_POLICY_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}}"
FACT_LIB="$ROOT/core/scripts/lib/trigger-fact-text.awk"
command -v jq >/dev/null || { echo "jq required"; exit 2; }
[ -r "$FACT_LIB" ] || { echo "missing $FACT_LIB"; exit 2; }
[ -r "$HOOK" ] || { echo "missing hook $HOOK"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Stand-in for `hq core derive-trigger-facts`, as in
# inject-policy-reminder-ceiling.test.sh.
cat > "$TMP/bin/hq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--version" ]; then printf '%s\n' 'hq 5.342.5'; exit 0; fi
event=""; with_intent=0
for arg in "$@"; do
  case "$arg" in
    PreToolUse|PostToolUse|UserPromptSubmit|AssistantIntent|SessionStart) event="$arg" ;;
    --with-assistant-intent) with_intent=1 ;;
  esac
done
payload="$(cat)"
case "$event" in
  PreToolUse) text="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')" ;;
  PostToolUse) text="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')" ;;
  UserPromptSubmit) text="$(printf '%s' "$payload" | jq -r '.prompt // ""')" ;;
  *) text="" ;;
esac
facts="always $(printf '%s\n' "$text" | awk -v mode=all -f "$FAKE_FACT_LIB" | tr '\n' ' ')"
if [ "$with_intent" -eq 1 ]; then printf '%s\n\n' "$facts"; else printf '%s\n' "$facts"; fi
EOF
chmod +x "$TMP/bin/hq"

failures=0
passes=0
ok() { printf 'ok   %s\n' "$1"; passes=$((passes + 1)); }
bad() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

new_root() {
  local dir="$TMP/$1"
  mkdir -p "$dir/core/policies" "$dir/workspace/orchestrator/policy-trigger-state"
  printf '%s' "$dir"
}
# policy <dir> <id> <when> <on> <enforcement> <inject> <body>
policy() {
  printf -- '---\nid: %s\nwhen: %s\non: [%s]\nenforcement: %s\ninject: %s\n---\n\n## Rule\n\n%s\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" > "$1/$2.md"
}
tool_event() { # <root> <sid> <command>
  jq -cn --arg sid "$2" --arg command "$3" \
    '{session_id:$sid,hook_event_name:"PostToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:$command},tool_response:{stdout:"ok",stderr:""}}' \
    | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$1" CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true
}
prompt_event() { # <root> <sid> <prompt> — UserPromptSubmit context is plain stdout
  jq -cn --arg sid "$2" --arg prompt "$3" \
    '{session_id:$sid,hook_event_name:"UserPromptSubmit",cwd:"/tmp",prompt:$prompt}' \
    | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$1" CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>/dev/null || true
}
enforced() { # <root> <sid> <slug> — is the slug in the receipt-backed enforcement set?
  awk -F '\t' -v s="$3" '$1 == s { f = 1 } END { exit !f }' "$1/workspace/orchestrator/policy-enforcement/$2.policies.tsv" 2>/dev/null
}
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

echo "[1] a HARD inject: always rule prints its full text once per session"
R1="$(new_root once)"
policy "$R1/core/policies" deploy-always-hard deploy 'PreToolUse, PostToolUse, UserPromptSubmit' hard always "Deploy rule. ALWAYS_DEPLOY_BODY"
p1="$(prompt_event "$R1" s1 'please deploy the site')"
p2="$(prompt_event "$R1" s1 'deploy it again please')"
p3="$(prompt_event "$R1" s1 'and deploy once more')"
has "$p1" ALWAYS_DEPLOY_BODY && ok "first turn shows the full text" || bad "first turn lacks the full text: $p1"
if has "$p2" ALWAYS_DEPLOY_BODY || has "$p3" ALWAYS_DEPLOY_BODY; then
  bad "full text printed again on a later turn: $p2 / $p3"
else
  ok "later turns do not repeat the full text"
fi
has "$p2" '> Already shown this session, still binding: deploy-always-hard' \
  && ok "a later turn names the rule in the footer" || bad "later turn lacks the footer: $p2"
enforced "$R1" s1 deploy-always-hard && ok "the rule stays in the enforcement set on a later turn" \
  || bad "the rule left the enforcement set once its text was not repeated"
p4="$(prompt_event "$R1" s2 'deploy in a new session')"
has "$p4" ALWAYS_DEPLOY_BODY && ok "a new session shows the full text again" || bad "new session lacks the full text: $p4"

echo "[2] a rule unrelated to the action is deferred to the next prompt; a subject match prints once"
R2="$(new_root unrelated)"
policy "$R2/core/policies" always-everywhere-hard always 'PreToolUse, PostToolUse, UserPromptSubmit' hard once "Unconditional rule. UNCONDITIONAL_BODY"
policy "$R2/core/policies" session-baseline-hard always 'SessionStart' hard once "Baseline rule. BASELINE_BODY"
policy "$R2/core/policies" session-generic-hard 'company' 'SessionStart' hard once "Generic-word SessionStart rule. GENERIC_BODY"
policy "$R2/core/policies" session-conditional-hard 'acme' 'SessionStart' hard once "Conditional SessionStart rule. COMPANY_BODY"
# A run with no UserPromptSubmit at all (a subagent, headless or overnight run).
t1="$(tool_event "$R2" s1 'gh pr view 12 --company acme')"
t2="$(tool_event "$R2" s1 'gh pr view 13 --company acme')"
t3="$(tool_event "$R2" s1 'gh pr view 14 --company acme')"
for slug in always-everywhere-hard session-baseline-hard session-generic-hard; do
  n=0
  for ev in "$t1" "$t2" "$t3"; do has "$ev" "\`$slug\`" && n=$((n + 1)); done
  [ "$n" -eq 0 ] && ok "$slug is not printed on a tool call it does not match" || bad "$slug printed on $n unrelated tool calls"
  enforced "$R2" s1 "$slug" && ok "$slug is in the enforcement set" || bad "$slug was dropped from the enforcement set"
done
# The owner decision on #1688 still holds for a genuine match: printed on its
# first tool event with no prompt, and not again.
has "$t1" '`session-conditional-hard`' \
  && ok "a SessionStart rule naming a subject in the command prints on the first tool event" \
  || bad "session-conditional-hard never printed in a run with no prompt: $t1"
n=0
for ev in "$t1" "$t2" "$t3"; do has "$ev" 'Policy `session-conditional-hard`' && n=$((n + 1)); done
[ "$n" -le 1 ] && ok "session-conditional-hard is not printed again on a later tool event" || bad "session-conditional-hard printed $n times"
enforced "$R2" s1 session-conditional-hard && ok "session-conditional-hard is in the enforcement set" || bad "session-conditional-hard dropped from enforcement"
# The deferred rules reach the model on the next prompt.
p2="$(prompt_event "$R2" s1 'what next')"
for slug in always-everywhere-hard session-baseline-hard session-generic-hard; do
  has "$p2" "\`$slug\`" && ok "$slug is delivered on the next prompt" || bad "$slug not delivered on the next prompt: $p2"
done
# A rule whose summary line was delivered earlier (seen set) is a repeat: it
# stays out of the reminder after its seen-set window expires.
R2b="$(new_root repeat-after-ttl)"
policy "$R2b/core/policies" session-baseline-hard always 'SessionStart' hard once "Baseline rule. BASELINE_BODY"
printf 'session-baseline-hard\t1\tev:always\n' > "$R2b/workspace/orchestrator/policy-trigger-state/s1.seen.tsv"
r1="$(tool_event "$R2b" s1 'gh pr view 12')"
has "$r1" '`session-baseline-hard`' && bad "an already-delivered baseline rule repeated on a tool event: $r1" || ok "an already-delivered baseline rule is not repeated"
enforced "$R2b" s1 session-baseline-hard && ok "the repeat is still handed to enforcement" || bad "the repeat left the enforcement set"

# A rule the generic cap parked unseen (seen entry marked `parked`) was never
# delivered, so it is not a repeat: its next tool-event match prints it.
R2c="$(new_root parked-not-delivered)"
policy "$R2c/core/policies" session-deploy-soft vercel 'SessionStart' soft once "Soft deploy note. SOFT_DEPLOY_BODY"
parked_at=$(( $(date +%s) - 4000 ))
printf 'session-deploy-soft\t%s\tev:vercel\tparked\n' "$parked_at" > "$R2c/workspace/orchestrator/policy-trigger-state/s1.seen.tsv"
c1="$(tool_event "$R2c" s1 'vercel deploy site')"
has "$c1" '`session-deploy-soft`' && ok "a parked, undelivered rule still prints on its next tool-event match" || bad "a parked rule was treated as delivered: $c1"
enforced "$R2c" s1 session-deploy-soft && ok "the first-match row is in the enforcement set" || bad "first-match row missing from enforcement"

echo "[3] a genuine HARD trigger is still injected on the tool event"
R3="$(new_root genuine)"
policy "$R3/core/policies" gh-pr-hard 'gh && pr' 'PreToolUse, PostToolUse, UserPromptSubmit' hard once "Gh PR rule. GH_PR_BODY"
policy "$R3/core/policies" tool-only-always always 'PostToolUse' hard once "Tool-only rule. TOOL_ONLY_BODY"
policy "$R3/core/policies" always-everywhere-hard always 'PreToolUse, PostToolUse, UserPromptSubmit' hard once "Unconditional rule. UNCONDITIONAL_BODY"
t1="$(tool_event "$R3" s1 'gh pr view 12')"
has "$t1" '`gh-pr-hard`' && ok "the matching HARD rule is injected" || bad "matching HARD rule missing: $t1"
has "$t1" GH_PR_BODY && ok "the matching HARD rule keeps its full text" || bad "matching HARD rule lost its full text: $t1"
has "$t1" '`tool-only-always`' && ok "a tool-only unconditional rule still fires on its event" || bad "tool-only rule missing: $t1"
t2="$(tool_event "$R3" s1 'gh pr view 13')"
has "$t2" '`always-everywhere-hard`' && bad "unconditional rule rode along again on the next gh call: $t2" || ok "the unconditional rule does not ride along twice"

printf '\n%s passed, %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
