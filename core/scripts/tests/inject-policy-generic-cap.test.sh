#!/usr/bin/env bash
# hq-core: public
# inject-policy-generic-cap.test.sh
#
# Regression contract for root cause RC4 of the 2026-10-21 feedback sweep
# (feedback_b4602c17, _e5c5d107, _3c8e7c87, _10ff20bf, _4e3f4b72, _03c2e4fe,
# _d39a7487, _0941bfc1, _f43754eb, _e4cef868, _7e2d3299): policy reminders of
# 6-17 KB on nearly every tool call, HARD rules cut to one-liners, the same
# rows cycling turn after turn. Updated 2026-10-22 for the reminder-ceiling
# design: a HARD rule listed as one line is parked in the seen set for its
# trigger key and named in the "Already shown" footer afterwards, instead of
# being deferred and re-listed; the per-call ceiling is 4000 bytes.
#   [1] a tool event whose command matches soft notes on ONE common word
#       parks them; HARD rules keyed on the head word (`git`) are listed,
#       one in full and the rest as one line, and the next command with the
#       same word names them only in the footer. A specific match on the
#       same event is unaffected.
#   [2] a prompt is not generic-capped: the relevance cap (6) applies and the
#       soft rows left out stay eligible, as before.
#   [3] a reactive HARD rule that loses the full-text budget is listed as one
#       line, parked for its trigger, and shown in full after the window.
#   [4] a HARD rule whose body is over the per-policy limit shows its `## Rule`
#       section when that fits, is recorded as delivered, and does not repeat.
#       A rule whose Rule section is itself over the limit keeps the oversize
#       summary and its notice.
#   [5] a command that matches nothing emits nothing.
#   [6] HQ_POLICY_GENERIC_CAP=0 turns the generic cap off: soft one-word rows
#       are not parked (they stay eligible behind the HARD rows).
#   [7] under the output ceiling every listed or cut HARD rule is parked and
#       comes back in full after the window, never twice.
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
seen_of() { printf '%s/workspace/orchestrator/policy-trigger-state/%s.seen.tsv' "$1" "$2"; }

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

echo "[1] a tool event parks the one-word soft notes and lists the head-word HARD rules once"
R1="$(new_root git)"
seed_git "$R1"
out="$(run "$R1" s1 'git -C /tmp/x status --short')"
case "$out" in
  *'> Policy `zz-git-status` (HARD — binding rule from `'*STATUS_BODY*) ok "the specific HARD rule is shown in full" ;;
  *) bad "specific HARD rule missing: $out" ;;
esac
n_hard="$(printf '%s\n' "$out" | grep -c '^> Policy `aa-git-hard-.*\[HARD · core\]' || true)"
[ "$n_hard" -ge 2 ] && ok "$n_hard head-word HARD rules are listed as one line" || bad "$n_hard aa-git-hard lines, expected at least 2: $out"
case "$out" in
  *'> Policy `ab-git-soft-'*) bad "a generic soft note took a generic slot: $out" ;;
  *) ok "generic soft notes are parked behind the HARD rules" ;;
esac
case "$out" in
  *'> Skipped: 8 matched only common words (parked 30 min).'*) ok "notice counts the 8 parked soft rows" ;;
  *) bad "skip notice missing or wrong: $out" ;;
esac
case "$out" in
  *'> Output budget 4000 bytes: '*' HARD policies listed as one line.'*) ok "budget notice counts the HARD rules listed as one line" ;;
  *) bad "budget notice missing or wrong: $out" ;;
esac
n="$(bytes_of "$out")"
[ "$n" -le 4000 ] && ok "reminder is $n bytes" || bad "reminder is $n bytes, over 4000"
seen="$(seen_of "$R1" s1)"
[ "$(grep -c '^ab-git-soft-' "$seen" 2>/dev/null || true)" = 8 ] && ok "the 8 soft rows are parked in the seen set" || bad "parked soft rows: $(grep -c '^ab-git-soft-' "$seen" 2>/dev/null || true), expected 8"
[ "$(grep -c '^aa-git-hard-.*	ev:git$' "$seen" 2>/dev/null || true)" = "$n_hard" ] && ok "every HARD rule listed as one line is parked on ev:git ($n_hard); cut rows are not" || bad "parked HARD rows: $(grep -c '^aa-git-hard-' "$seen" 2>/dev/null || true), expected $n_hard: $(cat "$seen" 2>/dev/null)"
listed_first="$(slugs "$out")"
ledger_has "$R1" zz-git-status s1 && ok "the rule shown in full is in the session ledger" || bad "zz-git-status not in the session ledger"
! ledger_has "$R1" aa-git-hard-01 s1 && ok "a rule listed as one line is not consumed by the session ledger" || bad "aa-git-hard-01 was consumed"
again="$(run "$R1" s1 'git -C /tmp/x status --short')"
repeat=0
for s in $(slugs "$again"); do printf '%s\n' "$listed_first" | grep -x "$s" >/dev/null && repeat=$((repeat + 1)); done
[ "$repeat" = 0 ] && ok "the same command again repeats no delivered row" || bad "repeat command repeated $repeat rows: $again"
[ "$(slugs "$again" | grep -c '^aa-git-hard-' || true)" = $((10 - n_hard)) ] && ok "the rows cut on the first event are listed on the second ($((10 - n_hard)))" || bad "second event lists $(slugs "$again" | grep -c '^aa-git-hard-' || true) HARD rows: $again"
case "$again" in
  *'> Already shown this session, still binding: zz-git-status, aa-git-hard-01'*) ok "the footer names the rules shown before, in rank order" ;;
  *) bad "footer missing or wrong: $again" ;;
esac
case "$again" in *ab-git-soft*) bad "a parked soft row is named: $again" ;; *) ok "parked soft rows are not named" ;; esac
again="$(run "$R1" s1 'git -C /tmp/x log --oneline -5')"
[ "$(policy_lines "$again")" = 0 ] && ok "once every git rule is delivered, another git command within the window lists nothing" || bad "another git command listed rows: $again"
case "$again" in
  *'> Already shown this session, still binding: '*'aa-git-hard-01'*) ok "the footer names the git rules, not the status rule" ;;
  *) bad "footer wrong for git log: $again" ;;
esac
case "$again" in *zz-git-status*) bad "zz-git-status named although it did not match: $again" ;; *) ok "a rule that did not match is not named" ;; esac
out="$(run "$R1" s1 'hq dm send --to ops "post it on slack"')"
case "$out" in
  *'> Policy `zz-slack-only` (HARD — binding rule from `'*SLACK_BODY*) ok "a different word still fires its rule in full" ;;
  *) bad "slack rule missing: $out" ;;
esac
# After the parking window the HARD rules listed as one line come back, the
# top-ranked one in full; the rule already shown in full stays in the footer.
out="$(run "$R1" s1 'git -C /tmp/x status' HQ_POLICY_SEEN_TTL_SECONDS=0)"
case "$out" in
  *'> Policy `aa-git-hard-'*'` (HARD — binding rule from `'*GIT_HARD_BODY_*) ok "after the window a HARD rule listed before is shown in full" ;;
  *) bad "no HARD rule in full after the window: $out" ;;
esac
case "$out" in *STATUS_BODY*|*'> Policy `zz-git-status`'*) bad "a recorded rule repeated: $out" ;; *) ok "the rule shown in full before is not repeated" ;; esac
case "$out" in *'> Already shown this session, still binding: '*'zz-git-status'*) ok "and it is still named in the footer" ;; *) bad "footer missing zz-git-status: $out" ;; esac

echo "[2] a prompt keeps the relevance cap alone"
R2="$(new_root prompt)"
seed_git "$R2"
out="$(prompt "$R2" s2 'please check the git history and tell me what changed')"
n="$(full_count "$out")"
[ "$n" -ge 1 ] && ok "prompt: $n one-word HARD rules fit the budget in full" || bad "prompt shows $n full bodies: $out"
case "$out" in *'[HARD · '*) ok "prompt: the other HARD rules are listed as one line" ;; *) bad "prompt: no HARD one-line summaries: $out" ;; esac
case "$out" in
  *'> Output budget 4000 bytes: '*' HARD policies listed as one line; 8 soft matches not shown.'*) ok "prompt: soft rows over the cap are counted" ;;
  *) bad "prompt notice missing or wrong: $out" ;;
esac
case "$out" in *'> Skipped:'*) bad "prompt: rows were parked by the generic cap: $out" ;; *) ok "prompt: no generic cap" ;; esac
! grep -q '^ab-git-soft-' "$(seen_of "$R2" s2)" 2>/dev/null && ok "prompt: soft rows over the cap are not parked" || bad "prompt: soft rows were parked"
# On a prompt there is no head word, so `git` (19 of 20 policies) scores 0:
# a score-0 rule listed as one line is recorded in the session ledger.
grep -q '^aa-git-hard-' "$R2/workspace/orchestrator/policy-trigger-state/s2.txt" 2>/dev/null && ok "prompt: score-0 HARD rules listed as one line are recorded as delivered" || bad "prompt: no listed HARD rule recorded"

echo "[3] a reactive HARD rule that loses the budget is listed as one line and parked"
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
[ "$n" = 1 ] && ok "one specific rule takes the 2600-byte full-text budget" || bad "expected 1 full body, found $n: $out"
case "$out" in
  *'> Policy `zz-specific-b` (HARD — binding rule from `'*SPEC_B_BODY*) ok "the higher-scored rule (two rare words) is the one in full" ;;
  *) bad "zz-specific-b not in full: $out" ;;
esac
case "$out" in
  *'> Policy `zz-specific-a` applies here:'*'[HARD · core]'*) ok "the rule that lost the budget is listed as one line" ;;
  *) bad "zz-specific-a not listed as one line: $out" ;;
esac
case "$out" in
  *'> Output budget 4000 bytes: 3 HARD policies listed as one line.'*) ok "budget notice counts the three one-line HARD rules" ;;
  *) bad "budget notice missing or wrong: $out" ;;
esac
case "$out" in *'Full-text budget of'*|*'> Deferred,'*) bad "an old notice is still printed: $out" ;; *) ok "no old notice" ;; esac
ledger_has "$R3" zz-specific-b s3 && ok "delivered specific rule recorded" || bad "zz-specific-b not recorded"
! ledger_has "$R3" zz-specific-a s3 && ok "the one-line rule is not consumed by the session ledger" || bad "zz-specific-a was recorded although listed as one line"
grep -q '^zz-specific-a	[0-9]*	ev:deploy+vercel$' "$(seen_of "$R3" s3)" 2>/dev/null \
  && ok "the one-line rule is parked on its trigger key" || bad "zz-specific-a not parked: $(cat "$(seen_of "$R3" s3)" 2>/dev/null)"
out="$(run "$R3" s3 'hq deploy vercel prod')"
[ "$(policy_lines "$out")" = 0 ] && ok "the same command again lists nothing" || bad "repeat listed rows: $out"
case "$out" in
  *'> Already shown this session, still binding: '*'zz-specific-b'*'zz-specific-a'*|*'> Already shown this session, still binding: '*'zz-specific-a'*'zz-specific-b'*) ok "the footer names the rule shown in full and the one listed as one line" ;;
  *) bad "footer wrong: $out" ;;
esac
out="$(run "$R3" s3 'hq deploy vercel prod' HQ_POLICY_SEEN_TTL_SECONDS=0)"
case "$out" in
  *'> Policy `zz-specific-a` (HARD — binding rule from `'*SPEC_A_BODY*) ok "after the window the one-line rule is shown in full" ;;
  *) bad "zz-specific-a did not come back in full: $out" ;;
esac
case "$out" in *SPEC_B_BODY*) bad "the rule shown in full before was repeated: $out" ;; *) ok "no repeat of the recorded rule" ;; esac

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
ledger_has "$R4" zz-huge-rule s4 && ok "a rule that can never print in full is recorded in the session ledger" || bad "zz-huge-rule not recorded"
out="$(run "$R4" s4 'hq deploy vercel prod')"
case "$out" in *'> Policy `zz-long-tail`'*) bad "Rule-section delivery repeated: $out" ;; *) ok "not repeated as a line on the next event" ;; esac

echo "[5] a command that matches nothing emits nothing"
R5="$(new_root nomatch)"
seed_git "$R5"
raw="$(jq -cn '{session_id:"s5",hook_event_name:"PostToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:"ls -la /tmp/x"},tool_response:{stdout:"total 0",stderr:""}}' | hook "$R5")"
[ -z "$raw" ] && ok "no match, no stdout" || bad "no-match event emitted: $raw"

echo "[6] HQ_POLICY_GENERIC_CAP=0 turns the generic cap off"
R6="$(new_root nocap)"
seed_git "$R6"
out="$(run "$R6" s6 'git -C /tmp/x status --short' HQ_POLICY_GENERIC_CAP=0)"
n="$(full_count "$out")"
[ "$n" -ge 1 ] && ok "generic cap off: $n HARD rules in full (the budget)" || bad "generic cap off: $n full bodies: $out"
case "$out" in
  *'> Output budget 4000 bytes: '*' HARD policies listed as one line; 8 soft matches not shown.'*) ok "generic cap off: soft rows over the relevance cap are counted, not parked" ;;
  *) bad "generic cap off: notice wrong: $out" ;;
esac
case "$out" in *'> Skipped:'*) bad "generic cap off: rows were parked by the generic cap: $out" ;; *) ok "generic cap off: no skip notice" ;; esac
! grep -q '^ab-git-soft-' "$(seen_of "$R6" s6)" 2>/dev/null && ok "generic cap off: no soft row parked" || bad "generic cap off: soft rows were parked"

echo "[7] under the output ceiling, listed and cut HARD rules are parked and drain"
R7="$(new_root ceiling-park)"
for i in $(seq -w 1 80); do
  policy "$R7" "hard-deploy-$i" deploy hard "Deploy rule $i."
done
for i in $(seq 1 8); do
  policy "$R7" "soft-deploy-$i" deploy soft "Soft deploy note $i."
done
out="$(run "$R7" s7 'deploy prod')"
shown=0
for i in $(seq -w 1 80); do
  case "$out" in *'> Policy `hard-deploy-'"$i"'`'*) shown=$((shown + 1)) ;; esac
done
n="$(bytes_of "$out")"
[ "$n" -le 4000 ] && ok "ceiling fixture stays under 4000 bytes ($n)" || bad "reminder is $n bytes"
[ "$shown" -lt 80 ] && [ "$shown" -gt 0 ] && ok "$shown of 80 HARD rules listed; the rest cut" || bad "$shown of 80 listed"
parked="$(grep -c '^hard-deploy-.*	ev:deploy$' "$(seen_of "$R7" s7)" 2>/dev/null || true)"
[ "$parked" = $((shown - 1)) ] && ok "the HARD rules listed as one line are parked ($parked); the one in full is in the ledger; cut rows are not recorded" || bad "$parked parked, expected $((shown - 1))"
first7="$(slugs "$out")"
again="$(run "$R7" s7 'deploy prod')"
repeat=0
for s in $(slugs "$again"); do printf '%s\n' "$first7" | grep -x "$s" >/dev/null && repeat=$((repeat + 1)); done
[ "$repeat" = 0 ] && [ "$(policy_lines "$again")" -gt 0 ] && ok "the same command again lists only rows cut the first time ($(policy_lines "$again"))" || bad "repeat: $repeat repeated, $(policy_lines "$again") lines: $again"
case "$again" in
  *'> Already shown this session, still binding: hard-deploy-01, '*) ok "the footer names the rules delivered before" ;;
  *) bad "footer missing or wrong: $again" ;;
esac
n="$(bytes_of "$again")"
[ "$n" -le 4000 ] && ok "second reminder is $n bytes" || bad "second reminder is $n bytes"
R7B="$(new_root ceiling-drain)"
big7="$(printf 'body text %.0s' $(seq 1 190))"   # ~1.9 KB, under the 2 KB per-policy limit
for i in 1 2 3 4 5 6 7; do
  policy "$R7B" "spec-hard-$i" 'git && status' hard "Spec rule $i. $big7 SPEC_END_$i"
done
out="$(run "$R7B" s7b 'git status')"
[ "$(full_count "$out")" = 1 ] && ok "fixture: one rule in full on the first event" || bad "fixture: $(full_count "$out") full bodies: $out"
[ "$(grep -c '^spec-hard-' "$(seen_of "$R7B" s7b)" 2>/dev/null || true)" = 6 ] \
  && ok "the six rules listed as one line are parked" || bad "parked spec-hard rows: $(cat "$(seen_of "$R7B" s7b)" 2>/dev/null)"
full_seen=" $(printf '%s\n' "$out" | sed -n 's/^> Policy `\([^`]*\)` (HARD — binding rule from .*/\1/p') "
again="$(run "$R7B" s7b 'git status')"
[ "$(policy_lines "$again")" = 0 ] && ok "inside the window the same command lists nothing" || bad "repeat listed rows: $again"
for i in 1 2 3 4 5 6 7 8; do
  outn="$(run "$R7B" s7b 'git status' HQ_POLICY_SEEN_TTL_SECONDS=0)"
  for slug in $(printf '%s\n' "$outn" | sed -n 's/^> Policy `\([^`]*\)` (HARD — binding rule from .*/\1/p'); do
    case "$full_seen" in *" $slug "*) bad "$slug shown in full twice" ;; esac
    full_seen="$full_seen$slug "
  done
done
for i in 1 2 3 4 5 6 7; do
  case "$full_seen" in *" spec-hard-$i "*) ;; *) bad "spec-hard-$i never reached full text: $full_seen" ;; esac
done
ok "after the window every rule listed as one line reached full text once ($full_seen)"

printf '\n%d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
