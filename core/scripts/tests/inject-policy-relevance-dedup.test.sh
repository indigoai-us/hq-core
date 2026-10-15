#!/usr/bin/env bash
# hq-core: public
# inject-policy-relevance-dedup.test.sh
#
# Regression contract for the policy-reminder flood (feedback_10ff20bf,
# feedback_e389a8df, feedback_b4602c17, feedback_ddf0470d):
#   [1] PostToolUse words printed by a read (cat/ls) do not match a policy that
#       also listens on PreToolUse; the same policy still fires, with its HARD
#       text, when the command itself names the trigger.
#   [2] a policy that listens on PostToolUse without PreToolUse still matches
#       words in tool output.
#   [3] an omitted `on:` keys on the command, not on tool output.
#   [4] structured output facts still match: a leaked key in output is
#       `apikey`; the word "main" in output is not `shared_branch`.
#   [5] when JSON quoting pushes the PostToolUse envelope over the ceiling,
#       the reminder is refit and the delivered policies are recorded, instead
#       of a bare "Policies matched." that records nothing and repeats.
#   [6] the malformed-`when:` notice names a slug once per session, while the
#       malformed HARD policy itself stays reachable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${HQ_TEST_INJECT_POLICY_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
FACT_LIB="$ROOT/core/scripts/lib/trigger-fact-text.awk"
command -v jq >/dev/null || { echo "jq required"; exit 2; }
[ -r "$FACT_LIB" ] || { echo "missing $FACT_LIB"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Stand-in for `hq core derive-trigger-facts`: the documented per-event source
# text (PreToolUse -> command, PostToolUse -> tool output, UserPromptSubmit ->
# prompt) tokenized by the real shared fact library.
cat > "$TMP/bin/hq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--version" ]; then printf '%s\n' 'hq 5.342.5'; exit 0; fi
event=""; with_intent=0
for arg in "$@"; do
  case "$arg" in
    PreToolUse|PostToolUse|UserPromptSubmit|AssistantIntent) event="$arg" ;;
    --with-assistant-intent) with_intent=1 ;;
  esac
done
payload="$(cat)"
case "$event" in
  PreToolUse) text="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')" ;;
  PostToolUse) text="$(printf '%s' "$payload" | jq -r 'if (.tool_response|type)=="string" then .tool_response else (.tool_response|tostring) end')" ;;
  UserPromptSubmit) text="$(printf '%s' "$payload" | jq -r '.prompt // ""')" ;;
  *) text="" ;;
esac
facts="always $(printf '%s\n' "$text" | awk -v mode=all -f "$FAKE_FACT_LIB" | tr '\n' ' ')"
if [ "$with_intent" -eq 1 ]; then printf '%s\n\n' "$facts"; else printf '%s\n' "$facts"; fi
EOF
chmod +x "$TMP/bin/hq"

failures=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

new_root() {
  local dir="$TMP/$1"
  mkdir -p "$dir/core/policies" "$dir/workspace/orchestrator/policy-trigger-state"
  printf '%s' "$dir"
}
policy() { # <root> <id> <when> <on-line or ''> <enforcement> <rule>
  local file="$1/core/policies/$2.md"
  {
    printf -- '---\nid: %s\nwhen: %s\n' "$2" "$3"
    [ -z "$4" ] || printf 'on: %s\n' "$4"
    printf 'enforcement: %s\n---\n\n## Rule\n\n%s\n' "$5" "$6"
  } > "$file"
}
post() { # <root> <sid> <command> <tool-output> [env...]
  local root="$1" sid="$2" command="$3" response="$4"
  shift 4
  jq -cn --arg sid "$sid" --arg command "$command" --arg response "$response" \
    '{session_id:$sid,hook_event_name:"PostToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:$command},tool_response:{stdout:$response,stderr:""}}' \
    | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" "$@" bash "$HOOK" 2>/dev/null
}
prompt() { # <root> <sid> <prompt> [env...]
  local root="$1" sid="$2" text="$3"
  shift 3
  jq -cn --arg sid "$sid" --arg prompt "$text" \
    '{session_id:$sid,hook_event_name:"UserPromptSubmit",cwd:"/tmp",prompt:$prompt}' \
    | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" "$@" bash "$HOOK" 2>/dev/null
}
context() { jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true; }

ALL_EVENTS='[PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]'

echo "[1] output words of a plain read do not match an action-keyed policy"
R1="$(new_root relevance)"
policy "$R1" slack-rule slack "$ALL_EVENTS" hard "ALWAYS route Slack posts through the hq-slack skill."
policy "$R1" deploy-rule 'deploy || feedback || done' "$ALL_EVENTS" soft "Verify the deploy end to end."
out="$(post "$R1" s1 'cat notes.txt' 'Post this to slack after the deploy is done. feedback welcome.' | context)"
case "$out" in *slack-rule*|*deploy-rule*) bad "cat output matched action-keyed policies: $out" ;; *) ok "cat output words matched nothing" ;; esac
out="$(post "$R1" s1 'hq slack read --channel general' 'a.txt b.txt' | context)"
case "$out" in
  *'`slack-rule` (HARD'*'hq-slack skill'*) ok "HARD policy still fires with full text when the command names it" ;;
  *) bad "command naming the trigger did not fire the HARD policy: $out" ;;
esac
out="$(post "$R1" s1 'hq slack read --channel general' 'a.txt b.txt' | context)"
case "$out" in *slack-rule*) bad "delivered policy re-sent in the same session: $out" ;; *) ok "delivered policy is not re-sent in the same session" ;; esac

echo "[2] a PostToolUse-only listener still keys on tool output"
R2="$(new_root output-listener)"
policy "$R2" printed-rule deploy '[PostToolUse]' soft "Read the deploy log tail."
out="$(post "$R2" s2 'cat build.log' 'deploy finished' | context)"
case "$out" in *printed-rule*) ok "output-specific policy matched printed word" ;; *) bad "output-specific policy lost its output match: $out" ;; esac

echo "[3] an omitted on: keys on the command"
R3="$(new_root omitted-on)"
policy "$R3" omitted-rule vercel '' soft "Check the Vercel team scope."
out="$(post "$R3" s3 'cat notes.txt' 'vercel vercel vercel' | context)"
case "$out" in *omitted-rule*) bad "omitted-on policy matched output words: $out" ;; *) ok "omitted-on policy ignores output words" ;; esac
out="$(post "$R3" s3 'vercel ls' 'ok' | context)"
case "$out" in *omitted-rule*) ok "omitted-on policy matches the command" ;; *) bad "omitted-on policy missed its command: $out" ;; esac

echo "[4] structured output facts"
R4="$(new_root structured)"
policy "$R4" leak-rule apikey '[PreToolUse, PostToolUse]' hard "Rotate any key printed to the transcript."
policy "$R4" branch-rule shared_branch '[PreToolUse, PostToolUse]' soft "Never push to a shared branch."
# Assembled at run time: a synthetic, key-shaped value for the apikey fact.
synthetic_key="sk-"
synthetic_key+="fixture0notreal"
out="$(post "$R4" s4 'cat config.txt' "value $synthetic_key on main" | context)"
case "$out" in *leak-rule*) ok "leaked key in output still yields apikey" ;; *) bad "structured apikey fact lost: $out" ;; esac
case "$out" in *branch-rule*) bad "the word main in output became shared_branch: $out" ;; *) ok "output word main is not shared_branch" ;; esac

echo "[5] JSON envelope overflow is refit and recorded"
R5="$(new_root envelope)"
quoted="$(printf '\\"q\\" %.0s' $(seq 1 30))"
for i in 1 2 3 4 5 6 7 8; do
  policy "$R5" "quoted-$i" always '[PostToolUse]' soft "$quoted"
done
raw="$(post "$R5" s5 'cat a' 'x' HQ_POLICY_OUTPUT_CEILING_BYTES=2000)"
bytes="$(printf '%s\n' "$raw" | wc -c | tr -d ' ')"
out="$(printf '%s' "$raw" | context)"
[ "$bytes" -le 2000 ] && ok "envelope within ceiling ($bytes bytes)" || bad "envelope $bytes bytes exceeds 2000"
case "$out" in
  'Policies matched.') bad "reminder collapsed to 'Policies matched.' (nothing recorded)" ;;
  *'> Policy `quoted-'*) ok "refit reminder delivers policies" ;;
  *) bad "no policy delivered: $raw" ;;
esac
ledger="$R5/workspace/orchestrator/policy-trigger-state/s5.txt"
first_delivered="$(printf '%s' "$out" | { grep -o 'Policy `quoted-[0-9]*`' || true; } | sed 's/Policy `//; s/`//' | sort)"
recorded="$(grep -E '^quoted-' "$ledger" 2>/dev/null | sort || true)"
[ -n "$first_delivered" ] && [ "$first_delivered" = "$recorded" ] \
  && ok "delivered policies recorded in the session ledger" \
  || bad "ledger [$recorded] does not match delivered [$first_delivered]"
out2="$(post "$R5" s5 'cat a' 'x' HQ_POLICY_OUTPUT_CEILING_BYTES=2000 | context)"
repeat=0
for slug in $first_delivered; do case "$out2" in *"\`$slug\`"*) repeat=1 ;; esac; done
[ "$repeat" -eq 0 ] && ok "second event does not repeat delivered policies" || bad "second event repeated delivered policies: $out2"
case "$out2" in *'> Policy `quoted-'*) ok "second event delivers the remaining policies" ;; *) bad "remaining policies not delivered: $out2" ;; esac

echo "[6] malformed when: notice once per session"
R6="$(new_root malformed)"
long="$(printf 'deploy rule detail %.0s' $(seq 1 7))"
for i in 1 2 3 4 5 6; do
  policy "$R6" "deploy-$i" deploy '[UserPromptSubmit]' soft "$long"
done
policy "$R6" broken-hard 'deploy &&' '[UserPromptSubmit]' hard "NEVER deploy without the checklist."
policy "$R6" broken-hard-b 'deploy &&' '[UserPromptSubmit]' hard "NEVER deploy without the second checklist."
t1="$(prompt "$R6" s6 'deploy round 1' HQ_POLICY_OUTPUT_CEILING_BYTES=900)"
case "$t1" in *'Malformed `when:` trigger'*broken-hard*) ok "first event names the malformed trigger" ;; *) bad "malformed notice missing on first event: $t1" ;; esac
case "$t1" in *'> Policy `broken-hard'*) bad "fixture did not cut the malformed policy line on the first event: $t1" ;; esac
t2="$(prompt "$R6" s6 'deploy round 2' HQ_POLICY_OUTPUT_CEILING_BYTES=900)"
case "$t2" in *'Malformed `when:`'*) bad "malformed notice repeated on a later event: $t2" ;; *) ok "malformed notice not repeated" ;; esac
case "$t2" in *'</policy-reminder>') ;; *) bad "reminder is not closed by an unindented tag: $t2" ;; esac
prompt "$R6" s6 'deploy round 3' HQ_POLICY_OUTPUT_CEILING_BYTES=900 >/dev/null
prompt "$R6" s6 'deploy round 4' HQ_POLICY_OUTPUT_CEILING_BYTES=900 >/dev/null
grep -Fxq broken-hard "$R6/workspace/orchestrator/policy-trigger-state/s6.txt" 2>/dev/null \
  && grep -Fxq broken-hard-b "$R6/workspace/orchestrator/policy-trigger-state/s6.txt" 2>/dev/null \
  && ok "malformed HARD policies are still delivered" || bad "malformed HARD policy never delivered"

if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures"
  exit 1
fi
echo "PASS"
