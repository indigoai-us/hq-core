#!/usr/bin/env bash
# hq-core: public
# inject-policy-generic-cap.test.sh
#
# Regression contract for root cause RC4 of the 2026-10-21 feedback sweep
# (feedback_b4602c17, _e5c5d107, _3c8e7c87, _10ff20bf, _4e3f4b72, _03c2e4fe,
# _d39a7487, _0941bfc1, _f43754eb, _e4cef868, _7e2d3299): policy reminders of
# 6-17 KB on nearly every tool call, HARD rules cut to one-liners, the same
# rows cycling turn after turn.
#   [1] a tool event whose command matches policies on ONE common word shows
#       at most HQ_POLICY_GENERIC_CAP (2) of them, HARD first, parks the rest
#       on that word, and the next command with the same word shows nothing.
#       A specific match on the same event is unaffected.
#   [2] a prompt is not generic-capped: the relevance cap (6) applies and the
#       rows left out stay eligible, as before.
#   [3] a reactive HARD rule that loses the shared full-text budget is
#       deferred, never a one-line summary: no `applies here:` line, not
#       recorded, shown in full on the next event once the rules that took
#       the budget are recorded.
#   [4] a HARD rule whose body is over the per-policy limit shows its `## Rule`
#       section when that fits, is recorded as delivered, and does not repeat.
#       A rule whose Rule section is itself over the limit keeps the oversize
#       summary and its notice.
#   [5] a command that matches nothing emits nothing.
#   [6] HQ_POLICY_GENERIC_CAP=0 restores the #1526 behaviour (six slots, the
#       rest eligible later).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${HQ_TEST_INJECT_POLICY_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
FACT_LIB="$ROOT/core/scripts/lib/trigger-fact-text.awk"
command -v jq >/dev/null || { echo "jq required"; exit 2; }
[ -r "$FACT_LIB" ] || { echo "missing $FACT_LIB"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Stand-in for `hq core derive-trigger-facts`: the per-event source text
# tokenized by the real shared fact library.
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
  PostToolUse) text="$(printf '%s' "$payload" | jq -r 'if (.tool_response|type)=="string" then .tool_response else (.tool_response|tostring) end')" ;;
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
policy() { # <root> <id> <when> <enforcement> <body-after-## Rule heading>
  printf -- '---\nid: %s\nwhen: %s\non: [PreToolUse, PostToolUse, UserPromptSubmit]\nenforcement: %s\n---\n\n## Rule\n\n%s\n' \
    "$2" "$3" "$4" "$5" > "$1/core/policies/$2.md"
}
hook() { # <root> [env...] < json
  local root="$1"
  shift
  env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" "$@" bash "$HOOK" 2>/dev/null
}
# PostToolUse reminder text for a Bash command (command facts are evaluated
# for policies that also list PreToolUse).
run() { # <root> <sid> <command> [env...]
  local root="$1" sid="$2" command="$3"
  shift 3
  jq -cn --arg sid "$sid" --arg command "$command" \
    '{session_id:$sid,hook_event_name:"PostToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:$command},tool_response:{stdout:"ok",stderr:""}}' \
    | hook "$root" "$@" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true
}
prompt() { # <root> <sid> <prompt> [env...]
  local root="$1" sid="$2" text="$3"
  shift 3
  jq -cn --arg sid "$sid" --arg text "$text" \
    '{session_id:$sid,hook_event_name:"UserPromptSubmit",cwd:"/tmp",prompt:$text}' \
    | hook "$root" "$@" || true
}
bytes_of() { printf '%s\n' "$1" | wc -c | tr -d ' '; }
slugs() { printf '%s\n' "$1" | sed -n 's/^> Policy `\([^`]*\)`.*/\1/p'; }
policy_lines() { printf '%s\n' "$1" | grep -c '^> Policy `' || true; }
full_count() { printf '%s\n' "$1" | grep -c '(HARD — binding rule from `' || true; }
ledger_has() { grep -qx "$2" "$1/workspace/orchestrator/policy-trigger-state/$3.txt" 2>/dev/null; }

FILLER="$(printf 'filler text for the body %.0s' $(seq 1 50))"   # ~1.25 KB

# Fixture: the reported shape. A read-only session runs `git status`; in this
# HQ ten HARD rules and eight soft notes key on the common word `git`, one
# HARD rule keys on `git && status` (specific), one on `slack` (no match).
seed_git() {
  local root="$1" i
  for i in $(seq -w 1 10); do
    policy "$root" "aa-git-hard-$i" git hard "Common git rule $i. GIT_HARD_BODY_$i $FILLER"
  done
  for i in $(seq -w 1 8); do
    policy "$root" "ab-git-soft-$i" git soft "Soft git note $i."
  done
  policy "$root" zz-git-status 'git && status' hard "Read the status before acting. STATUS_BODY $FILLER"
  policy "$root" zz-slack-only slack hard "Slack rule. SLACK_BODY"
}

echo "[1] a tool event shows at most 2 one-word matches, parks the rest on the word"
R1="$(new_root git)"
seed_git "$R1"
out="$(run "$R1" s1 'git -C /tmp/x status --short')"
case "$out" in
  *'> Policy `zz-git-status` (HARD — binding rule from `'*STATUS_BODY*) ok "the specific HARD rule is shown in full" ;;
  *) bad "specific HARD rule missing: $out" ;;
esac
n="$(printf '%s\n' "$out" | grep -c '^> Policy `aa-git-hard-' || true)"
[ "$n" = 2 ] && ok "2 generic HARD rules shown (generic cap 2)" || bad "$n generic HARD rules shown, expected 2: $out"
case "$out" in
  *'> Policy `ab-git-soft-'*) bad "a generic soft note took a generic slot: $out" ;;
  *) ok "generic soft notes are parked behind the HARD rules" ;;
esac
case "$out" in
  *'> Relevance cap 6: 8 lower-ranked soft matches not shown; every HARD match is shown or named above. 8 matched only one common word and are parked on it for 30 min (`ab-git-soft-1`, '*'`ab-git-soft-8`), 0 still eligible later.'*) ok "notice names the 8 parked soft rows" ;;
  *) bad "parked notice missing or wrong: $out" ;;
esac
case "$out" in *'[HARD · '*) bad "a HARD rule was shortened to a one-line summary: $out" ;; *) ok "no HARD one-line summaries" ;; esac
n="$(bytes_of "$out")"
[ "$n" -le 5000 ] && ok "reminder is $n bytes" || bad "reminder is $n bytes, expected under 5000"
seen="$R1/workspace/orchestrator/policy-trigger-state/s1.seen.tsv"
[ "$(grep -c '' "$seen" 2>/dev/null || echo 0)" = 8 ] && ok "only the 8 soft rows are parked in the seen set" || bad "seen set has $(grep -c '' "$seen" 2>/dev/null || echo 0) rows, expected 8"
grep -q 'aa-git-hard-' "$seen" 2>/dev/null && bad "a HARD row was parked: $(cat "$seen")" || ok "no HARD row is parked (PR #1548 review)"
case "$out" in
  *'> Deferred, full-text budget of 5120 bytes spent: HARD policies `aa-git-hard-03`, '*'`aa-git-hard-10` are not shown'*) ok "every other one-word HARD rule is named as deferred" ;;
  *) bad "deferred HARD rules not named: $out" ;;
esac
again="$(run "$R1" s1 'git -C /tmp/x status --short')"
case "$again" in
  *'> Policy `ab-git-soft-'*|*GIT_HARD_BODY_01*|*GIT_HARD_BODY_02*|*STATUS_BODY*) bad "repeat command repeated a shown or parked row: $again" ;;
  *'> Policy `aa-git-hard-03` (HARD'*) ok "the same command again shows only the next deferred HARD rules, nothing repeated" ;;
  *) bad "repeat command did not continue the deferred HARD rules: $again" ;;
esac
again="$(run "$R1" s1 'git -C /tmp/x log --oneline -5')"
case "$again" in
  *'> Policy `ab-git-soft-'*|*GIT_HARD_BODY_03*|*STATUS_BODY*) bad "another git command repeated a shown or parked row: $again" ;;
  *) ok "another git command within the window repeats nothing and shows no parked soft row" ;;
esac
out="$(run "$R1" s1 'hq dm send --to ops "post it on slack"')"
case "$out" in
  *'> Policy `zz-slack-only` (HARD — binding rule from `'*SLACK_BODY*) ok "a different word still fires its rule in full" ;;
  *) bad "slack rule missing: $out" ;;
esac
# After the parking window the next git command shows the next two.
out="$(run "$R1" s1 'git -C /tmp/x status' HQ_POLICY_SEEN_TTL_SECONDS=0)"
n="$(printf '%s\n' "$out" | grep -c '^> Policy `aa-git-hard-' || true)"
[ "$n" = 2 ] && ok "after the window, the next 2 generic HARD rules are shown" || bad "$n generic HARD rules after the window: $out"
case "$out" in *GIT_HARD_BODY_01*|*GIT_HARD_BODY_02*) bad "a recorded rule repeated: $out" ;; *) ok "the rules shown before are not repeated" ;; esac

echo "[2] a prompt keeps the relevance cap alone"
R2="$(new_root prompt)"
seed_git "$R2"
out="$(prompt "$R2" s2 'please check the git history and tell me what changed')"
n="$(full_count "$out")"
[ "$n" = 3 ] && ok "prompt: 3 one-word HARD rules fit the budget in full (no generic cap)" || bad "prompt shows $n full bodies, expected 3: $out"
case "$out" in
  *'> Deferred, full-text budget of 5120 bytes spent: HARD policies `aa-git-hard-04`, '*'`aa-git-hard-10` are not shown'*) ok "prompt: every other HARD match is deferred by name" ;;
  *) bad "prompt deferred notice missing or wrong: $out" ;;
esac
case "$out" in *'[HARD · '*) bad "prompt: a HARD rule was shortened to a one-line summary: $out" ;; *) ok "prompt: no HARD one-line summaries" ;; esac
case "$out" in
  *'> Relevance cap 6: 8 lower-ranked soft matches not shown; every HARD match is shown or named above.'*) ok "prompt: soft rows over the cap stay eligible (nothing parked)" ;;
  *) bad "prompt notice missing or wrong: $out" ;;
esac
[ ! -s "$R2/workspace/orchestrator/policy-trigger-state/s2.seen.tsv" ] && ok "prompt: nothing parked" || bad "prompt: rows were parked"

echo "[3] a reactive HARD rule that loses the budget is deferred, not summarised"
R3="$(new_root budget)"
big="$(printf 'body text %.0s' $(seq 1 190))"   # ~1.9 KB, under the 2 KB per-policy limit
policy "$R3" zz-specific-a 'deploy && vercel' hard "Specific A. SPEC_A_BODY $big"
policy "$R3" zz-specific-b 'vercel && prod' hard "Specific B. SPEC_B_BODY $big"
policy "$R3" aa-common-1 deploy hard "Common 1. COMMON_1_BODY $FILLER"
policy "$R3" aa-common-2 deploy hard "Common 2. COMMON_2_BODY $FILLER"
for i in 1 2 3 4; do
  policy "$R3" "ab-common-soft-$i" deploy soft "Soft deploy note $i."   # makes deploy a common word
done
out="$(run "$R3" s3 'hq deploy vercel prod')"
n="$(full_count "$out")"
[ "$n" = 2 ] && ok "the 2 specific rules take the budget" || bad "expected 2 full bodies, found $n: $out"
case "$out" in
  *'> Policy `aa-common-'*'applies here:'*) bad "a HARD rule that lost the budget was shortened to one line: $out" ;;
  *) ok "no one-line HARD summary" ;;
esac
case "$out" in
  *'> Deferred, full-text budget of 5120 bytes spent: HARD policies `aa-common-1`, `aa-common-2` are not shown as one-line summaries; each stays eligible'*) ok "deferred notice names both rules" ;;
  *) bad "deferred notice missing or wrong: $out" ;;
esac
case "$out" in *'Full-text budget of'*) bad "the old shortened notice is still printed: $out" ;; *) ok "no shortened notice" ;; esac
ledger_has "$R3" zz-specific-a s3 && ok "delivered specific rule recorded" || bad "zz-specific-a not recorded"
! ledger_has "$R3" aa-common-1 s3 && ok "deferred rule not recorded" || bad "aa-common-1 was recorded although deferred"
! grep -q 'aa-common-1' "$R3/workspace/orchestrator/policy-trigger-state/s3.seen.tsv" 2>/dev/null \
  && ok "deferred rule not parked either" || bad "aa-common-1 was parked"
out="$(run "$R3" s3 'hq deploy vercel prod')"
case "$out" in
  *'> Policy `aa-common-1` (HARD — binding rule from `'*COMMON_1_BODY*'> Policy `aa-common-2` (HARD — binding rule from `'*COMMON_2_BODY*) ok "on the next event both deferred rules are shown in full" ;;
  *) bad "deferred rules did not come back in full: $out" ;;
esac

echo "[4] over the per-policy limit, a HARD rule falls back to its Rule section"
R4="$(new_root rule-floor)"
scope_text="$(printf 'scope detail %.0s' $(seq 1 160))"   # ~2 KB of non-Rule text
policy "$R4" zz-long-tail 'deploy && vercel' hard "Check the Vercel team before a deploy. RULE_ONLY_BODY"$'\n\n## Scope\n\n'"$scope_text SCOPE_MARKER"
huge_rule="$(printf 'rule text %.0s' $(seq 1 260))"   # ~2.6 KB inside ## Rule
policy "$R4" zz-huge-rule 'vercel && prod' hard "Huge rule. HUGE_RULE_BODY $huge_rule"
out="$(run "$R4" s4 'hq deploy vercel prod')"
case "$out" in
  *'> Policy `zz-long-tail` (HARD — Rule section from `'*'the full text is over the 2048-byte per-policy limit'*RULE_ONLY_BODY*) ok "Rule section delivered with its own heading" ;;
  *) bad "Rule section not delivered: $out" ;;
esac
case "$out" in *SCOPE_MARKER*) bad "the non-Rule section was printed: $out" ;; *) ok "only the Rule section was printed" ;; esac
case "$out" in
  *'> Policy `zz-long-tail` applies here:'*) bad "zz-long-tail was shortened to one line: $out" ;;
  *) ok "zz-long-tail is not a one-line summary" ;;
esac
case "$out" in
  *'> Policy `zz-huge-rule` applies here:'*'> Over the 2048-byte per-policy limit, so shortened to one-line summaries — zz-huge-rule.'*) ok "a Rule section over the limit keeps the oversize summary and notice" ;;
  *) bad "oversize contract changed: $out" ;;
esac
ledger_has "$R4" zz-long-tail s4 && ok "Rule-section delivery is recorded" || bad "zz-long-tail not recorded"
out="$(run "$R4" s4 'hq deploy vercel prod')"
case "$out" in *zz-long-tail*) bad "Rule-section delivery repeated: $out" ;; *) ok "not repeated on the next event" ;; esac

echo "[5] a command that matches nothing emits nothing"
R5="$(new_root nomatch)"
seed_git "$R5"
raw="$(jq -cn '{session_id:"s5",hook_event_name:"PostToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:"ls -la /tmp/x"},tool_response:{stdout:"total 0",stderr:""}}' | hook "$R5")"
[ -z "$raw" ] && ok "no match, no stdout" || bad "no-match event emitted: $raw"

echo "[6] HQ_POLICY_GENERIC_CAP=0 restores the six-slot behaviour"
R6="$(new_root nocap)"
seed_git "$R6"
out="$(run "$R6" s6 'git -C /tmp/x status --short' HQ_POLICY_GENERIC_CAP=0)"
n="$(full_count "$out")"
[ "$n" = 3 ] && ok "generic cap off: 3 HARD rules in full (the budget)" || bad "generic cap off: $n full bodies: $out"
case "$out" in
  *'> Deferred, full-text budget of 5120 bytes spent: HARD policies `aa-git-hard-03`, `aa-git-hard-04`, `aa-git-hard-05`'*) ok "generic cap off: the other slot holders are deferred" ;;
  *) bad "generic cap off: deferred notice wrong: $out" ;;
esac
case "$out" in
  *'> Relevance cap 6: 8 lower-ranked soft matches not shown; every HARD match is shown or named above.'*) ok "generic cap off: soft rows stay eligible" ;;
  *) bad "generic cap off: notice wrong: $out" ;;
esac
[ ! -s "$R6/workspace/orchestrator/policy-trigger-state/s6.seen.tsv" ] && ok "generic cap off: nothing parked" || bad "generic cap off: rows were parked"

echo "[7] after the output ceiling, the HARD claim is true and shortened HARD rules are not parked"
R7="$(new_root ceiling-claim)"
for i in $(seq -w 1 80); do
  policy "$R7" "hard-deploy-$i" deploy hard "Deploy rule $i."
done
for i in $(seq 1 8); do
  policy "$R7" "soft-deploy-$i" deploy soft "Soft deploy note $i."
done
out="$(run "$R7" s7 'deploy prod')"
shown=0
for i in $(seq -w 1 80); do
  case "$out" in *'`hard-deploy-'"$i"'`'*) shown=$((shown + 1)) ;; esac
done
n="$(bytes_of "$out")"
[ "$n" -le 8000 ] && ok "ceiling fixture stays under 8000 bytes ($n)" || bad "reminder is $n bytes"
if [ "$shown" -lt 80 ]; then
  case "$out" in
    *'every HARD match is shown or named above'*) bad "claims every HARD match is shown with $shown of 80 present: $out" ;;
    *) ok "no all-HARD claim when the ceiling cut HARD rows ($shown of 80 present)" ;;
  esac
  case "$out" in
    *"$((80 - shown)) HARD cut by ceiling; still eligible."*) ok "the notice counts the $((80 - shown)) HARD rows the ceiling cut" ;;
    *) bad "cut count missing or wrong ($shown of 80 present): $out" ;;
  esac
else
  ok "all 80 HARD rows fit; claim may stay"
fi
R7B="$(new_root ceiling-park)"
big7="$(printf 'body text %.0s' $(seq 1 190))"   # ~1.9 KB, under the 2 KB per-policy limit
for i in 1 2 3 4 5 6 7; do
  policy "$R7B" "spec-hard-$i" 'git && status' hard "Spec rule $i. $big7 SPEC_END_$i"
done
out="$(run "$R7B" s7b 'git status')"
short=""
for i in 1 2 3 4 5 6 7; do
  case "$out" in *"SPEC_END_$i"*) ;; *) short="$short $i" ;; esac
done
if [ -n "$short" ]; then
  ok "fixture: rules shortened or deferred on the first event:$short"
  ! grep -q 'spec-hard-' "$R7B/workspace/orchestrator/policy-trigger-state/s7b.seen.tsv" 2>/dev/null \
    && ok "no shortened HARD rule is written to the seen set" \
    || bad "shortened HARD rules were parked: $(cat "$R7B/workspace/orchestrator/policy-trigger-state/s7b.seen.tsv")"
  again="$(run "$R7B" s7b 'git status')"
  first="${short# }"; first="${first%% *}"
  case "$again" in
    *"SPEC_END_$first"*) ok "a rule shortened on the first event is shown in full on the next (spec-hard-$first)" ;;
    *) bad "spec-hard-$first did not come back in full: $again" ;;
  esac
else
  bad "fixture did not hit the ceiling: $out"
fi

printf '\n%d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
