#!/usr/bin/env bash
# hq-core: public
# inject-policy-tool-subject-match.test.sh
#
# Regression contract for feedback_9eda6433 (duplicates feedback_ff1c11af,
# feedback_eddb8326): tool-call policy reminders were mostly unrelated to the
# command. On PreToolUse/PostToolUse a rule is shown only when its `when:`
# matched the tool call on a SUBJECT word: an identifier in the command or
# tool input that is not one of the generic words in TOOL_STOP_WORDS_DEFAULT.
#   [1] the stop-word list is explicit and holds the named generic words
#   [2] a match on generic words only is not shown; the HARD row stays in the
#       enforcement set and the rule is delivered on the next prompt
#   [3] a real subject match is kept, with the HARD full text, and ranks ahead
#       of generic matches inside the byte ceiling
#   [4] a SessionStart-only rule with no subject match is deferred to the next
#       prompt; one with a subject match prints on its first tool event
#   [5] an unparseable `when:` is not shown on an unrelated tool call (no
#       fallback line, no notice) and its HARD row stays in enforcement
#   [6] enforcement is unchanged: a HARD gate rule matched only on a generic
#       word still blocks the outbound action on PreToolUse
#   [7] a rule that listens only on tool events keeps matching there
#   [8] the deferred queue is capped (HQ_POLICY_TOOL_DEFERRED_CAP, default 5
#       soft rules per session); overflow is dropped, HARD rules are always
#       queued, and a delivered queue is not reprinted
#
# HOOK (or HQ_TEST_INJECT_POLICY_HOOK) points the run at another copy of the
# hook, e.g. main's, to show these cases fail there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${HOOK:-${HQ_TEST_INJECT_POLICY_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}}"
FACT_LIB="$ROOT/core/scripts/lib/trigger-fact-text.awk"
command -v jq >/dev/null || { echo "jq required"; exit 2; }
[ -r "$FACT_LIB" ] || { echo "missing $FACT_LIB"; exit 2; }
[ -r "$HOOK" ] || { echo "missing hook $HOOK"; exit 2; }
unset HQ_POLICY_TOOL_STOP_WORDS HQ_POLICY_TOOL_BASELINE HQ_POLICY_GENERIC_CAP

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Stand-in for `hq core derive-trigger-facts`, as in
# inject-policy-tool-relevance.test.sh.
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
  PreToolUse|PostToolUse) text="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')" ;;
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
# policy <dir> <id> <when> <on> <enforcement> <body> [extra frontmatter line]
policy() {
  printf -- '---\nid: %s\nwhen: %s\non: [%s]\nenforcement: %s\n%s---\n\n## Rule\n\n%s\n' \
    "$2" "$3" "$4" "$5" "${7:+$7
}" "$6" > "$1/$2.md"
}
tool_event() { # <root> <sid> <command> [event] [env...]
  local root="$1" sid="$2" command="$3" ev="${4:-PostToolUse}"
  shift 3; [ "$#" -gt 0 ] && shift
  jq -cn --arg sid "$sid" --arg command "$command" --arg ev "$ev" \
    '{session_id:$sid,hook_event_name:$ev,tool_name:"Bash",cwd:"/tmp",tool_input:{command:$command},tool_response:{stdout:"ok",stderr:""}}' \
    | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" "$@" bash "$HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true
}
prompt_event() { # <root> <sid> <prompt>
  jq -cn --arg sid "$2" --arg prompt "$3" \
    '{session_id:$sid,hook_event_name:"UserPromptSubmit",cwd:"/tmp",prompt:$prompt}' \
    | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$1" CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>/dev/null || true
}
enforced() { # <root> <sid> <slug>
  awk -F '\t' -v s="$3" '$1 == s { f = 1 } END { exit !f }' "$1/workspace/orchestrator/policy-enforcement/$2.policies.tsv" 2>/dev/null
}
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

echo "[1] the stop-word list is explicit"
stop_line="$(grep -E '^TOOL_STOP_WORDS_DEFAULT="' "$HOOK" || true)"
[ -n "$stop_line" ] && ok "the hook declares TOOL_STOP_WORDS_DEFAULT" || bad "no TOOL_STOP_WORDS_DEFAULT in the hook"
for w in deploy merge test session pr commit policy; do
  case " ${stop_line#*=\"} " in *" $w "*) ok "'$w' is a stop word" ;; *) bad "'$w' missing from the stop-word list" ;; esac
done
for w in vercel gh git hq-core-staging .claude/hooks; do
  case " ${stop_line#*=\"} " in *" $w "*) bad "'$w' must stay a subject word" ;; *) ok "'$w' is not a stop word" ;; esac
done

echo "[2] a generic-word-only match is skipped on the tool call"
R2="$(new_root generic)"
policy "$R2/core/policies" generic-hard 'deploy || merge' 'PreToolUse, PostToolUse, UserPromptSubmit' hard "Generic rule. GENERIC_HARD_BODY"
policy "$R2/core/policies" generic-soft 'test' 'PreToolUse, PostToolUse, UserPromptSubmit' soft "Generic soft note."
for w in deploy merge test session pr commit policy; do
  policy "$R2/core/policies" "word-$w" "$w" 'PreToolUse, PostToolUse, UserPromptSubmit' hard "Word rule $w."
done
g1="$(tool_event "$R2" s2 'hq deploy site')"
g2="$(tool_event "$R2" s2 'git merge main && pnpm test')"
has "$g1$g2" '`generic-hard`' && bad "generic-word match shown on the tool call: $g1 / $g2" || ok "generic-word HARD match not shown on the tool call"
has "$g1$g2" '`generic-soft`' && bad "generic-word soft match shown: $g2" || ok "generic-word soft match not shown on the tool call"
g3="$(tool_event "$R2" s2b 'x deploy merge test session pr commit policy')"
n=0
for w in deploy merge test session pr commit policy; do has "$g3" "\`word-$w\`" && n=$((n + 1)); done
[ "$n" -eq 0 ] && ok "no single-stop-word rule is shown on a tool call" || bad "$n single-stop-word rules shown: $g3"
enforced "$R2" s2 generic-hard && ok "generic-word HARD row is in the enforcement set" || bad "generic-word HARD row left the enforcement set"
for w in deploy merge test session pr commit policy; do
  enforced "$R2" s2b "word-$w" || bad "word-$w left the enforcement set"
done
ok "every single-stop-word HARD row checked against the enforcement set"
p2="$(prompt_event "$R2" s2 'please deploy the site')"
has "$p2" GENERIC_HARD_BODY && ok "the deferred rule is delivered on the next prompt" || bad "deferred rule not delivered on the next prompt: $p2"

echo "[3] a real subject match is kept and ranks first"
R3="$(new_root subject)"
policy "$R3/core/policies" vercel-hard 'vercel && deploy' 'PreToolUse, PostToolUse, UserPromptSubmit' hard "Vercel rule. VERCEL_BODY"
filler="$(printf 'filler text for the body %.0s' $(seq 1 40))"
for i in 1 2 3 4 5 6; do
  policy "$R3/core/policies" "aaa-generic-$i" deploy 'PreToolUse, PostToolUse, UserPromptSubmit' hard "Generic deploy rule $i. $filler"
done
s1="$(tool_event "$R3" s3 'vercel deploy --prod' PostToolUse HQ_POLICY_OUTPUT_CEILING_BYTES=1500)"
has "$s1" VERCEL_BODY && ok "the subject-matched HARD rule keeps its full text" || bad "subject-matched HARD rule missing or cut: $s1"
has "$s1" '`aaa-generic-' && bad "a generic-word rule took room in the reminder: $s1" || ok "generic-word rules take no room ahead of the subject match"
n="$(printf '%s\n' "$s1" | wc -c | tr -d ' ')"
[ "$n" -le 1500 ] && ok "the reminder stays inside the ceiling ($n bytes)" || bad "reminder is $n bytes"
for i in 1 2 3 4 5 6; do enforced "$R3" s3 "aaa-generic-$i" || bad "aaa-generic-$i left the enforcement set"; done
ok "generic-word HARD rows checked against the enforcement set"
policy "$R3/core/policies" gh-pr-hard 'gh && pr' 'PreToolUse, PostToolUse, UserPromptSubmit' hard "Gh PR rule. GH_PR_BODY"
s2="$(tool_event "$R3" s3b 'gh pr view 12')"
has "$s2" GH_PR_BODY && ok "a command word (gh) is a subject" || bad "gh && pr rule not shown: $s2"

echo "[4] a SessionStart-only rule with no subject match is deferred to the next prompt"
R4="$(new_root sessionstart)"
policy "$R4/core/policies" ss-always always 'SessionStart' hard "Baseline rule. SS_ALWAYS_BODY"
policy "$R4/core/policies" ss-generic 'session || commit' 'SessionStart' hard "Session rule. SS_GENERIC_BODY"
policy "$R4/core/policies" ss-subject 'acme' 'SessionStart' hard "Acme rule. SS_SUBJECT_BODY"
a1="$(tool_event "$R4" s4 'git commit -m wip --company acme')"
a2="$(tool_event "$R4" s4 'git commit -m wip2 --company acme')"
for slug in ss-always ss-generic; do
  has "$a1$a2" "\`$slug\`" && bad "$slug shown on a tool call it does not match: $a1 / $a2" || ok "$slug not shown on the tool call"
  enforced "$R4" s4 "$slug" && ok "$slug is in the enforcement set" || bad "$slug left the enforcement set"
done
has "$a1" SS_SUBJECT_BODY && ok "a subject-matched SessionStart rule prints on its first tool event with no prompt" || bad "ss-subject not printed: $a1"
has "$a2" 'Policy `ss-subject`' && bad "ss-subject printed again: $a2" || ok "ss-subject is not printed again"
a3="$(prompt_event "$R4" s4 'what next')"
has "$a3" SS_ALWAYS_BODY && ok "ss-always is delivered on the next prompt" || bad "ss-always not delivered on the next prompt: $a3"
# The prompt does not mention session or commit: the deferred conditional
# SessionStart rule is still delivered there, once.
has "$a3" SS_GENERIC_BODY && ok "ss-generic is delivered on the next prompt though the prompt does not match it" || bad "ss-generic not delivered on the next prompt: $a3"
a4="$(prompt_event "$R4" s4 'and then')"
has "$a4" 'Policy `ss-generic`' && bad "ss-generic delivered twice: $a4" || ok "a deferred rule is delivered once"
policy "$R4/core/policies" ss-always-soft 'commit' 'SessionStart' soft "Always soft. SS_ALWAYS_SOFT_BODY" 'inject: always'
tool_event "$R4" s4c 'git commit -m x' >/dev/null
b1="$(prompt_event "$R4" s4c 'first')"
b2="$(prompt_event "$R4" s4c 'second')"
has "$b1" SS_ALWAYS_SOFT_BODY && ok "a deferred inject: always rule is delivered on the next prompt" || bad "deferred always rule not delivered: $b1"
has "$b2" SS_ALWAYS_SOFT_BODY && bad "a deferred inject: always rule is re-delivered on every prompt: $b2" || ok "a delivered deferred rule leaves the queue"

echo "[4b] a higher-precedence copy narrowed on a tool event still wins over a lower copy"
R4b="$(new_root precedence)"
mkdir -p "$R4b/personal/policies"
policy "$R4b/personal/policies" dup-rule deploy 'PreToolUse, PostToolUse, UserPromptSubmit' hard "Personal override. PERSONAL_DUP_BODY"
policy "$R4b/core/policies" dup-rule vercel 'PreToolUse, PostToolUse, UserPromptSubmit' soft "Core copy. CORE_DUP_BODY"
d1="$(tool_event "$R4b" s4b 'vercel deploy site')"
has "$d1" CORE_DUP_BODY && bad "the lower-precedence copy was shown in place of the override: $d1" || ok "the lower-precedence copy is not shown"
row="$(awk -F '\t' '$1 == "dup-rule"' "$R4b/workspace/orchestrator/policy-enforcement/s4b.policies.tsv" 2>/dev/null | head -1)"
case "$row" in *"personal/policies/dup-rule.md"*hard*) ok "policies.tsv keeps the override's HARD row" ;; *) bad "policies.tsv row for dup-rule is not the HARD override: $row" ;; esac

echo "[5] an unparseable trigger is not shown on an unrelated tool call"
R5="$(new_root malformed)"
policy "$R5/core/policies" broken-hard 'secret || "api key"' 'PreToolUse, PostToolUse, UserPromptSubmit' hard "Broken rule. BROKEN_BODY"
policy "$R5/core/policies" broken-soft 'svelte || {#each}' 'PreToolUse, PostToolUse, UserPromptSubmit' soft "Broken soft rule."
m1="$(tool_event "$R5" s5 'ls -la /tmp')"
m2="$(tool_event "$R5" s5 'ls -la /tmp' PreToolUse)"
has "$m1$m2" '`broken-' && bad "malformed fallback shown on an unrelated tool call: $m1 / $m2" || ok "malformed fallback rows not shown on a tool call"
has "$m1$m2" 'Malformed `when:`' && bad "malformed notice shown on an unrelated tool call: $m1" || ok "no malformed notice on the tool call"
enforced "$R5" s5 broken-hard && ok "the malformed HARD row stays in the enforcement set" || bad "malformed HARD row left the enforcement set"
m3="$(prompt_event "$R5" s5 'hello')"
has "$m3" '`broken-hard`' && ok "the malformed HARD rule is still surfaced on the next prompt" || bad "malformed HARD rule never surfaced: $m3"

echo "[6] a HARD gate matched only on a generic word still blocks"
R6="$(new_root gate)"
mkdir -p "$R6/.claude/hooks"
cp "$ROOT/.claude/hooks/policy-enforcement-gate.sh" "$ROOT/.claude/hooks/hook-gate.sh" "$R6/.claude/hooks/"
[ -d "$ROOT/.claude/hooks/lib" ] && cp -R "$ROOT/.claude/hooks/lib" "$R6/.claude/hooks/lib"
policy "$R6/core/policies" report-gate 'report' 'PreToolUse, PostToolUse, UserPromptSubmit' hard "NEVER send internal notes. REPORT_BODY" 'delivery-forbid-regex: INTERNAL_ONLY'
cmd='MESSAGE="weekly report INTERNAL_ONLY"; hq dm general "$MESSAGE"'
set +e
blk="$(jq -cn --arg cmd "$cmd" '{session_id:"s6",hook_event_name:"PreToolUse",tool_name:"Bash",tool_use_id:"toolu_s6",cwd:"/tmp",tool_input:{command:$cmd}}' \
  | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$R6" CLAUDE_PROJECT_DIR="$R6" bash "$HOOK" 2>/dev/null)"
rc=$?
set -e
enforced "$R6" s6 report-gate && ok "the generic-word gate rule is in the enforcement set" || bad "report-gate left the enforcement set"
[ "$rc" -eq 2 ] && ok "the outbound action is blocked (exit 2)" || bad "outbound action not blocked (rc=$rc): $blk"
has "$blk" 'report-gate' && ok "the block names the policy" || bad "block reason lacks the policy id: $blk"

echo "[7] a rule that listens only on tool events keeps matching there"
R7="$(new_root tool-only)"
policy "$R7/core/policies" tool-only-deploy deploy 'PreToolUse, PostToolUse' hard "Read the deploy log. TOOL_ONLY_BODY"
t1="$(tool_event "$R7" s7 'hq deploy site')"
has "$t1" TOOL_ONLY_BODY && ok "a tool-only rule on a generic word still fires (it has no later delivery path)" || bad "tool-only generic-word rule missing: $t1"
policy "$R7/core/policies" tool-only-always always 'PreToolUse, PostToolUse' hard "Tool-only rule. TOOL_ALWAYS_BODY"
t2="$(tool_event "$R7" s7b 'ls')"
has "$t2" '`tool-only-always`' && ok "a tool-only unconditional rule still fires" || bad "tool-only unconditional rule missing: $t2"

echo "[8] the deferred queue is capped; HARD rules survive overflow"
# Owner decision on PR 1693: "Cap the queue, then merge". Eight soft
# SessionStart-only rules and one HARD one match a tool call on a generic
# word only. At most HQ_POLICY_TOOL_DEFERRED_CAP (default 5) soft rules are
# queued per session; the rest are dropped, the HARD rule is always queued.
R8="$(new_root deferred-cap)"
for i in 1 2 3 4 5 6; do
  policy "$R8/core/policies" "cap-soft-$i" 'commit' 'SessionStart' soft "Soft queued rule $i. CAP_SOFT_BODY_$i"
done
# Two rules match on more terms and score higher: they are queued ahead of
# lower-scored rules with smaller ids. Ties go by id.
for i in 7 8; do
  policy "$R8/core/policies" "cap-soft-$i" 'commit && merge' 'SessionStart' soft "Soft queued rule $i. CAP_SOFT_BODY_$i"
done
policy "$R8/core/policies" cap-hard 'commit' 'SessionStart' hard "Hard queued rule. CAP_HARD_BODY"
c1="$(tool_event "$R8" s8 'git commit -m one merge')"
c2="$(tool_event "$R8" s8 'git commit -m two merge')"
has "$c1$c2" '`cap-' && bad "a deferred rule was shown on the tool call: $c1 / $c2" || ok "no deferred rule shown on the tool calls"
qfile="$R8/workspace/orchestrator/policy-trigger-state/s8.deferred.tsv"
qsoft="$(grep -c '^cap-soft-' "$qfile" 2>/dev/null || true)"
[ "${qsoft:-0}" -eq 5 ] && ok "the queue holds 5 soft rules" || bad "the queue holds ${qsoft:-0} soft rules, want 5: $(cat "$qfile" 2>/dev/null | tr '\n' ' ')"
want="cap-soft-1 cap-soft-2 cap-soft-3 cap-soft-7 cap-soft-8"
got="$(grep '^cap-soft-' "$qfile" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
[ "$got" = "$want " ] && ok "the higher-scored soft rules are queued, ties by id" || bad "queued soft rules '$got', want '$want'"
grep -qx cap-hard "$qfile" 2>/dev/null && ok "the HARD rule is queued despite the overflow" || bad "the HARD rule was dropped from the queue"
enforced "$R8" s8 cap-hard && ok "cap-hard is in the enforcement set" || bad "cap-hard left the enforcement set"
for i in 1 2 3 4 5 6 7 8; do
  enforced "$R8" s8 "cap-soft-$i" || bad "cap-soft-$i left the enforcement set"
done
d1="$(prompt_event "$R8" s8 'what next')"
n=0
for i in 1 2 3 4 5 6 7 8; do has "$d1" "CAP_SOFT_BODY_$i" && n=$((n + 1)); done
[ "$n" -eq 5 ] && ok "the next prompt delivers 5 of 8 queued soft rules" || bad "the next prompt delivered $n soft rules, want 5: $d1"
has "$d1" CAP_HARD_BODY && ok "the next prompt delivers the HARD rule" || bad "HARD rule not delivered on the next prompt: $d1"
d2="$(prompt_event "$R8" s8 'and then')"
n2=0
for i in 1 2 3 4 5 6 7 8; do has "$d2" "CAP_SOFT_BODY_$i" && n2=$((n2 + 1)); done
[ "$n2" -eq 0 ] && ok "the dropped soft rules are not carried over to the second prompt" || bad "$n2 soft rules reached the second prompt: $d2"
has "$d2" CAP_HARD_BODY && bad "the HARD rule was reprinted: $d2" || ok "the queue does not reprint the HARD rule"
[ -s "$qfile" ] && bad "the queue is not empty after delivery: $(tr '\n' ' ' < "$qfile")" || ok "the queue is empty after delivery"
# The budget is per session: later tool events queue no further soft rules.
policy "$R8/core/policies" cap-soft-late 'push' 'SessionStart' soft "Late soft rule. CAP_SOFT_LATE_BODY"
l1="$(tool_event "$R8" s8 'git push')"
has "$l1" CAP_SOFT_LATE_BODY && bad "cap-soft-late shown on the tool call: $l1" || ok "cap-soft-late not shown on the tool call"
d3="$(prompt_event "$R8" s8 'next')"
has "$d3" CAP_SOFT_LATE_BODY && bad "a soft rule was queued after the session budget was used: $d3" || ok "the session budget stays used"
# Control: in a session with budget left, the same tool call queues it.
tool_event "$R8" s8c 'git push' >/dev/null
grep -qx cap-soft-late "$R8/workspace/orchestrator/policy-trigger-state/s8c.deferred.tsv" 2>/dev/null \
  && ok "control: with budget left the late rule is queued" || bad "control: cap-soft-late not queued in a fresh session"
d4="$(prompt_event "$R8" s8c 'next')"
has "$d4" CAP_SOFT_LATE_BODY && ok "control: the late rule is delivered on the next prompt" || bad "control: late rule not delivered: $d4"
# Env override.
R8b="$(new_root deferred-cap-env)"
for i in 1 2 3 4; do
  policy "$R8b/core/policies" "env-soft-$i" 'commit' 'SessionStart' soft "Env soft rule $i. ENV_SOFT_BODY_$i"
done
tool_event "$R8b" s8b 'git commit -m x' PostToolUse HQ_POLICY_TOOL_DEFERRED_CAP=2 >/dev/null
e1="$(prompt_event "$R8b" s8b 'what next')"
n=0
for i in 1 2 3 4; do has "$e1" "ENV_SOFT_BODY_$i" && n=$((n + 1)); done
[ "$n" -eq 2 ] && ok "HQ_POLICY_TOOL_DEFERRED_CAP=2 delivers 2 soft rules" || bad "HQ_POLICY_TOOL_DEFERRED_CAP=2 delivered $n soft rules: $e1"

echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
