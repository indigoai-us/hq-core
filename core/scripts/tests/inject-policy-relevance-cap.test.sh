#!/usr/bin/env bash
# hq-core: public
# inject-policy-relevance-cap.test.sh
#
# Regression contract for feedback feedback_34ab4b26: the policy reminder
# matched 20+ policies per event, most on one common word, and cut every HARD
# rule but one to its summary line.
#   [a] 25 policies match; the 3 HARD rules with a specific match (two
#       identifiers, or one rare identifier) rank first by score, the top one
#       prints in full and the others are listed as one line; HARD rules that
#       matched only the common word score 0 and are listed up to the
#       generic cap, the rest parked; soft common-word rows are parked.
#   [b] an event that matches only on one common word lists HARD matches up
#       to the generic cap and parks the rest; the next event with the same
#       word names them only in the footer.
#   [c] a HARD rule over the per-policy limit is still summarised with the
#       per-policy notice, even when its match is specific.
#   [d] over the output ceiling, soft lines go first; when full text still
#       does not fit, as many specific HARD rules as fit keep their text.
#   [e] SessionStart is not capped.
# 2026-10-21 (RC4 hook noise, stacked on #1526): on tool events at most
# HQ_POLICY_GENERIC_CAP (default 2) one-common-word matches are shown and the
# rest are parked on that word. 2026-10-22 (reminder-ceiling design): a HARD
# row scoring 0 (only common words) is generic too; a HARD rule that loses
# the full-text budget is listed as one line and parked for its trigger; the
# default ceiling is 4000 bytes. HQ_POLICY_GENERIC_CAP=0 keeps every HARD row
# listed; the generic-cap defaults have their own file,
# inject-policy-generic-cap.test.sh.
#   [f] specific SOFT hints and malformed fallbacks never push an applicable
#       HARD rule out.
set -euo pipefail
# These fixtures use common verbs (deploy, run, release) as neutral vehicle
# words for the cap and ceiling mechanics. The tool-event subject filter
# (feedback_9eda6433) would treat them as generic words and keep them off the
# tool call, so it is switched off here; inject-policy-tool-subject-match.test.sh
# covers the filter itself.
export HQ_POLICY_TOOL_STOP_WORDS=

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
policy() { # <root> <id> <when> <enforcement> <rule> [on]
  printf -- '---\nid: %s\nwhen: %s\non: [%s]\nenforcement: %s\n---\n\n## Rule\n\n%s\n' \
    "$2" "$3" "${6:-PreToolUse, PostToolUse, UserPromptSubmit}" "$4" "$5" > "$1/core/policies/$2.md"
}
hook() { # <root> [env...] < json
  local root="$1"
  shift
  env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" "$@" bash "$HOOK" 2>/dev/null
}
# Reminder text for a Bash PostToolUse. Command-keyed facts are evaluated for
# policies that also list PreToolUse.
run() { # <root> <sid> <command> [env...]
  local root="$1" sid="$2" command="$3"
  shift 3
  jq -cn --arg sid "$sid" --arg command "$command" \
    '{session_id:$sid,hook_event_name:"PostToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:$command},tool_response:{stdout:"ok",stderr:""}}' \
    | hook "$root" "$@" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true
}
bytes_of() { printf '%s\n' "$1" | wc -c | tr -d ' '; }
slugs() { printf '%s\n' "$1" | sed -n 's/^> Policy `\([^`]*\)`.*/\1/p'; }
policy_lines() { printf '%s\n' "$1" | grep -c '^> Policy `' || true; }
full_count() { printf '%s\n' "$1" | grep -c '(HARD — binding rule from `' || true; }
# Distinct HARD slugs with a prefix that are shown or named (Deferred notice).
hard_named() { printf '%s\n' "$1" | grep -o "\`$2[^\`]*\`" | sort -u | grep -c . || true; }

FILLER="$(printf 'filler text for the body %.0s' $(seq 1 50))"   # ~1.25 KB

# Fixture: 22 policies keyed only on the common word `deploy` (10 HARD, 12
# soft) and 3 HARD rules with a specific match: two identifiers each for two
# of them, one rare identifier for the third. 25 match `hq deploy vercel prod
# zebra-cluster`.
seed() {
  local root="$1" i
  for i in $(seq -w 1 10); do
    policy "$root" "aa-common-hard-$i" deploy hard "Common deploy rule $i. COMMON_BODY_$i $FILLER"
  done
  for i in $(seq -w 1 12); do
    policy "$root" "ab-common-soft-$i" deploy soft "Soft deploy note $i."
  done
  policy "$root" zz-specific-vercel 'deploy && vercel' hard "Check the Vercel team before a deploy. SPECIFIC_VERCEL_BODY $FILLER"
  policy "$root" zz-specific-prod 'vercel && prod' hard "Never ship to prod without a canary. SPECIFIC_PROD_BODY $FILLER"
  policy "$root" zz-specific-rare 'zebra-cluster' hard "The zebra cluster is shared. SPECIFIC_RARE_BODY $FILLER"
}

echo "[a] 25 matches: the specific HARD rules rank first by score; the top one is in full"
RA="$(new_root many)"
seed "$RA"
out="$(run "$RA" sa 'hq deploy vercel prod zebra-cluster')"
# Scores: prod (vercel + prod, two rare words) 4; vercel (common deploy +
# rare vercel) 2; rare (zebra-cluster) 2; the common-word HARD rules 0.
case "$out" in
  *'> Policy `zz-specific-prod` (HARD — binding rule from `'*SPECIFIC_PROD_BODY*) ok "the highest-scored specific HARD rule is printed in full" ;;
  *) bad "zz-specific-prod lost its full text: $out" ;;
esac
for s in vercel rare; do
  case "$out" in
    *'> Policy `zz-specific-'"$s"'`'*) ok "specific HARD rule ($s) is listed" ;;
    *) bad "specific HARD rule ($s) missing: $out" ;;
  esac
done
n="$(full_count "$out")"
[ "$n" -ge 1 ] && [ "$n" -le 2 ] && ok "$n full HARD bodies within the 2600-byte full-text budget" || bad "expected 1-2 full HARD bodies, found $n"
first="$(slugs "$out" | head -1)"
[ "$first" = zz-specific-prod ] && ok "the specific HARD rule with the highest score ranks first" || bad "first policy is $first"
first3="$(slugs "$out" | head -3 | sort | tr '\n' ' ')"
[ "$first3" = "zz-specific-prod zz-specific-rare zz-specific-vercel " ] \
  && ok "specific HARD rules rank first" || bad "first three policies are: $first3"
# The 10 HARD rules keyed on the common word `deploy` score 0. A HARD row is
# never parked (PR #1600 review): each is listed as one line or cut by the
# output ceiling and held for a later call. All 12 common-word soft rows are
# parked.
listed_a="$(printf '%s\n' "$out" | grep -c '^> Policy `aa-common-hard-.*\[HARD · core\]' || true)"
[ "$listed_a" -ge 3 ] && ok "score-0 HARD rules are not held to the generic cap ($listed_a listed as one line)" || bad "$listed_a common-word HARD lines, expected 3 or more: $out"
n="$(grep -c '^aa-common-hard-' "$RA/workspace/orchestrator/policy-trigger-state/sa.seen.tsv" 2>/dev/null || true)"
[ "$n" = 0 ] && ok "no score-0 HARD rule is parked in the seen set" || bad "$n common-word HARD rules parked, expected 0"
n="$(grep -c '^aa-common-hard-' "$RA/workspace/orchestrator/policy-trigger-state/sa.txt" 2>/dev/null || true)"
[ "$n" = "$listed_a" ] && ok "the $n score-0 HARD rules listed as one line are recorded in the session ledger (delivered)" || bad "$n listed score-0 HARD rules in the ledger, expected $listed_a"
n="$(printf '%s\n' "$out" | grep -c '^> Policy `ab-common-soft-' || true)"
[ "$n" = 0 ] && ok "common-word soft rows are left out" || bad "$n common-word soft rows shown"
case "$out" in
  *'> Skipped: 12 matched only common words (parked 30 min).'*) ok "skip notice counts the 12 soft rows parked and no HARD row" ;;
  *) bad "skip notice missing or wrong: $out" ;;
esac
case "$out" in
  *'> Output budget 4000 bytes: '*' HARD policies listed as one line.'*) ok "budget notice counts the HARD rules listed as one line" ;;
  *) bad "budget notice missing or wrong: $out" ;;
esac
case "$out" in *'> Deferred,'*|*'Full-text budget of'*|*'> Relevance cap'*) bad "an old notice is still printed: $out" ;; *) ok "no old notice" ;; esac
n="$(bytes_of "$out")"
[ "$n" -le 4000 ] && ok "reminder within the 4000-byte ceiling ($n bytes)" || bad "reminder is $n bytes"
# Without the generic cap every HARD row is listed; the soft rows over the
# relevance cap are counted, not parked.
RA0="$(new_root many-nocap)"
seed "$RA0"
out="$(run "$RA0" sa0 'hq deploy vercel prod zebra-cluster' HQ_POLICY_GENERIC_CAP=0)"
n="$(full_count "$out")"
[ "$n" -ge 1 ] && ok "generic cap off: $n specific HARD rules in full" || bad "generic cap off: no full HARD body: $out"
n="$(hard_named "$out" aa-common-hard-)"
[ "$n" -ge 3 ] && ok "generic cap off: common-word HARD rules are listed ($n)" || bad "generic cap off: $n common-word HARD rules listed: $out"
case "$out" in
  *' HARD policies listed as one line; 12 soft matches not shown.'*) ok "generic cap off: notice counts the 12 soft rows left out" ;;
  *) bad "generic cap off: notice missing or wrong: $out" ;;
esac
[ ! -s "$RA0/workspace/orchestrator/policy-trigger-state/sa0.seen.tsv" ] || ! grep -q '^ab-common-soft-' "$RA0/workspace/orchestrator/policy-trigger-state/sa0.seen.tsv" \
  && ok "generic cap off: soft rows over the cap are not parked" || bad "generic cap off: soft rows were parked"

# The full-text budget applies to specific HARD rules too: bodies are added
# in rank order while they fit, the rest are listed as one line.
RA2="$(new_root small-budget)"
seed "$RA2"
out="$(run "$RA2" sa2 'hq deploy vercel prod zebra-cluster' HQ_POLICY_HARD_BUDGET_BYTES=1500)"
n="$(full_count "$out")"
[ "$n" = 1 ] && ok "one specific HARD rule in full under a 1500-byte budget" || bad "expected 1 full HARD body under a small budget, found $n: $out"
case "$out" in *'> Policy `zz-specific-vercel` applies here:'*'> Policy `zz-specific-rare` applies here:'*|*'> Policy `zz-specific-rare` applies here:'*'> Policy `zz-specific-vercel` applies here:'*) ok "the other specific rules are listed as one line" ;; *) bad "specific rules over the budget not listed: $out" ;; esac

echo "[b] one common word: every HARD match is listed or held, none parked"
RB="$(new_root common)"
seed "$RB"
out="$(run "$RB" sb 'hq deploy')"
n="$(printf '%s\n' "$out" | grep -c '^> Policy `aa-common-hard-' || true)"
[ "$n" -ge 3 ] && ok "$n of 10 common-word HARD matches listed (no generic cap for HARD)" || bad "$n of 10 HARD matches listed: $out"
first_b="$(slugs "$out")"
n="$(printf '%s\n' "$out" | grep -c '^> Policy `ab-common-soft-' || true)"
[ "$n" = 0 ] && ok "no soft row takes a generic slot a HARD row needed" || bad "$n soft rows shown"
n="$(full_count "$out")"
[ "$n" -ge 1 ] && [ "$n" -le 2 ] && ok "HARD rules in full within the full-text budget ($n bodies)" || bad "$n full HARD bodies for a common-word match, expected 1-2"
case "$out" in
  *'> Skipped: 12 matched only common words (parked 30 min).'*) ok "skip notice counts the 12 soft rows parked and no HARD row" ;;
  *) bad "skip notice missing or wrong: $out" ;;
esac
n="$(bytes_of "$out")"
[ "$n" -le 4000 ] && ok "reminder within the 4000-byte ceiling ($n bytes)" || bad "reminder is $n bytes"
again="$(run "$RB" sb 'hq deploy')"
repeat=0
for s in $(slugs "$again"); do printf '%s\n' "$first_b" | grep -x "$s" >/dev/null && repeat=$((repeat + 1)); done
[ "$repeat" = 0 ] && ok "the same word again lists no row delivered on the first event" || bad "second event re-listed $repeat rows: $again"
missing=""
for i in 01 02 03 04 05 06 07 08 09 10; do
  printf '%s\n%s\n' "$first_b" "$(slugs "$again")" | grep -x "aa-common-hard-$i" >/dev/null || missing="$missing aa-common-hard-$i"
done
[ -z "$missing" ] && ok "every common-word HARD rule is delivered within two events" || bad "HARD rules never delivered:$missing"
case "$again" in
  *'> Already shown this session, still binding: aa-common-hard-01'*) ok "the footer names the HARD rules shown before" ;;
  *) bad "footer missing or wrong: $again" ;;
esac
case "$again" in *ab-common-soft*) bad "a parked soft row is named: $again" ;; *) ok "parked soft rows are not named" ;; esac
# Without the generic cap every HARD row is listed; the soft rows over the
# relevance cap stay eligible (not parked) but there is no slot for them.
RB1="$(new_root common-nocap)"
seed "$RB1"
out="$(run "$RB1" sb1 'hq deploy' HQ_POLICY_GENERIC_CAP=0)"
n="$(printf '%s\n' "$out" | grep -c '^> Policy `aa-common-hard-' || true)"
[ "$n" -ge 3 ] && ok "generic cap off: common-word HARD rules are listed ($n)" || bad "generic cap off: $n HARD rows listed: $out"
n="$(printf '%s\n' "$out" | grep -c '^> Policy `ab-common-soft-' || true)"
[ "$n" = 0 ] && ok "generic cap off: no soft row shown (HARD rows took the slots)" || bad "generic cap off: $n soft rows shown"
n="$(full_count "$out")"
[ "$n" -le 2 ] && ok "generic cap off: full text stays within the full-text budget ($n bodies)" || bad "generic cap off: $n full HARD bodies for a common-word match"
case "$out" in
  *' HARD policies listed as one line; 12 soft matches not shown.'*) ok "generic cap off: notice counts the 12 soft rows left out" ;;
  *) bad "generic cap off: notice missing or wrong: $out" ;;
esac
first_b1="$(slugs "$out")"
again="$(run "$RB1" sb1 'hq deploy' HQ_POLICY_GENERIC_CAP=0)"
repeat=0
for s in $(slugs "$again"); do printf '%s\n' "$first_b1" | grep -x "$s" >/dev/null && repeat=$((repeat + 1)); done
[ "$repeat" = 0 ] && ok "generic cap off: no row delivered on the first event is listed again" || bad "generic cap off: second event re-listed $repeat rows: $again"
case "$again" in *'> Already shown this session, still binding: aa-common-hard-01'*) ok "generic cap off: the footer names the HARD rows" ;; *) bad "generic cap off: footer missing: $again" ;; esac
out="$(run "$RB" sb0 'hq deploy' HQ_POLICY_RELEVANCE_CAP=0)"
case "$out" in
  *'> Skipped:'*) bad "HQ_POLICY_RELEVANCE_CAP=0 still parked rows: $out" ;;
  *) ok "HQ_POLICY_RELEVANCE_CAP=0 turns the cap off" ;;
esac

echo "[c] the per-policy limit still applies to a specific match"
RC="$(new_root oversize)"
big="$(printf 'oversized body text %.0s' $(seq 1 150))"   # ~3 KB
policy "$RC" zz-big-specific 'deploy && vercel' hard "Big rule. BIG_BODY $big"
policy "$RC" zz-small-specific 'vercel && prod' hard "Small rule. SMALL_BODY $FILLER"
out="$(run "$RC" sc 'hq deploy vercel prod')"
case "$out" in
  *'> Policy `zz-big-specific` applies here:'*) ok "oversized specific rule is a summary line" ;;
  *) bad "oversized specific rule not summarised: $out" ;;
esac
case "$out" in
  *'> Policy `zz-big-specific` (HARD — binding rule from `'*) bad "oversized body was printed: $out" ;;
  *) ok "oversized body not printed" ;;
esac
case "$out" in
  *'> Over the 2048-byte per-policy limit, so shortened to one-line summaries — zz-big-specific.'*) ok "per-policy notice names the oversized rule" ;;
  *) bad "per-policy notice missing: $out" ;;
esac
case "$out" in
  *'SMALL_BODY'*) ok "the other specific rule keeps its full text" ;;
  *) bad "the other specific rule lost its full text: $out" ;;
esac

echo "[d] over the ceiling: soft lines go first, then the fewest full texts"
RD="$(new_root ceiling)"
# The 3 specific HARD rules from seed(), 2 HARD rules on the common word
# `deploy`, and 3 soft rules with a specific match. The soft rules rank just
# below the specific HARD rules; the two common HARD rules after them are
# summary lines (the shared budget is spent).
for i in 1 2; do
  policy "$RD" "aa-common-hard-$i" deploy hard "Common deploy rule $i. COMMON_BODY_$i $FILLER"
done
policy "$RD" zz-specific-vercel 'deploy && vercel' hard "Check the Vercel team before a deploy. SPECIFIC_VERCEL_BODY $FILLER"
policy "$RD" zz-specific-prod 'vercel && prod' hard "Never ship to prod without a canary. SPECIFIC_PROD_BODY $FILLER"
policy "$RD" zz-specific-rare 'zebra-cluster' hard "The zebra cluster is shared. SPECIFIC_RARE_BODY $FILLER"
long_note="$(printf 'soft note text %.0s' $(seq 1 12))"
for i in 1 2 3; do
  policy "$RD" "ac-specific-soft-$i" 'deploy && vercel' soft "Specific soft note $i. $long_note"
done
# Unmatched filler so that `vercel` (5 of 28 policies) is not a common word
# in this small fixture, while `deploy` (6 of 28) still is.
for i in $(seq -w 1 20); do
  policy "$RD" "docker-note-$i" docker soft "Docker note $i."
done
# At the operator's 8000-byte ceiling the full-text budget is 5120 bytes:
# all three specific HARD rules print in full, the two common HARD rules
# (score 0) are listed as one line, the three specific soft hints are shown.
full="$(run "$RD" sd0 'hq deploy vercel prod zebra-cluster' HQ_POLICY_OUTPUT_CEILING_BYTES=8000)"
full_bytes="$(bytes_of "$full")"
[ "$(full_count "$full")" = 3 ] && ok "fixture: 3 specific HARD rules in full at the 8000-byte ceiling" || bad "fixture: $(full_count "$full") full bodies: $full"
case "$full" in
  *'> Policy `ac-specific-soft-'*'> Output budget 8000 bytes: 2 HARD policies listed as one line.'*) ok "fixture: soft lines are shown and the two common HARD rules are listed as one line" ;;
  *) bad "fixture ordering unexpected: $full" ;;
esac
# Room for the cut notice, minus about two soft lines: soft lines go first.
ceiling=$((full_bytes - 200))
out="$(run "$RD" sd 'hq deploy vercel prod zebra-cluster' HQ_POLICY_OUTPUT_CEILING_BYTES=$ceiling)"
n="$(bytes_of "$out")"
[ "$n" -le "$ceiling" ] && ok "reminder within the $ceiling-byte ceiling ($n bytes)" || bad "reminder is $n bytes, over $ceiling"
case "$out" in
  *'lower-ranked policy line(s) held for a later call'*) ok "notice says lines were cut" ;;
  *) bad "no cut notice: $out" ;;
esac
soft_left="$(printf '%s\n' "$out" | grep -c '^> Policy `ac-specific-soft-' || true)"
hard_left="$(printf '%s\n' "$out" | grep -c '^> Policy `aa-common-hard-.*\[HARD · core\]' || true)"
[ "$soft_left" -lt 3 ] && [ "$hard_left" = 2 ] \
  && ok "soft lines were cut before any HARD line" \
  || bad "expected soft lines cut and both HARD lines kept (soft=$soft_left hard=$hard_left): $out"
# At the 4000-byte default the full-text budget is 2600 bytes: one body.
out="$(run "$RD" sd2 'hq deploy vercel prod zebra-cluster')"
n="$(bytes_of "$out")"
[ "$n" -le 4000 ] && ok "reminder within the 4000-byte default ($n bytes)" || bad "reminder is $n bytes, over 4000"
n="$(full_count "$out")"
[ "$n" = 1 ] && ok "one specific HARD rule in full under the default budget" || bad "expected 1 full body, found $n: $out"
case "$out" in
  *'> Policy `zz-specific-prod` (HARD — binding rule from `'*) ok "the highest-scored rule is the one in full" ;;
  *) bad "zz-specific-prod not in full: $out" ;;
esac
case "$out" in
  *'> Output budget 4000 bytes: 4 HARD policies listed as one line.'*) ok "the other four HARD rules are counted as one-line listings" ;;
  *) bad "budget notice missing or wrong: $out" ;;
esac

echo "[f] specific SOFT hints never push an applicable HARD rule out (PR #1526 review)"
# Reviewer's exact case: `vercel deploy --prod` with six specific SOFT hints
# and one HARD rule keyed on the common word `deploy`.
RF="$(new_root applicable-hard)"
for i in 1 2 3 4 5 6; do
  policy "$RF" "vercel-soft-$i" 'deploy && vercel' soft "Vercel deployment presentation hint $i."
done
policy "$RF" production-approval deploy hard "Never deploy production without the owner approving the exact release. REQUIRE_PRODUCTION_APPROVAL"
out="$(run "$RF" sf 'vercel deploy --prod')"
case "$out" in
  *'> Policy `production-approval` (HARD — binding rule from `'*REQUIRE_PRODUCTION_APPROVAL*) ok "applicable HARD rule delivered in full" ;;
  *) bad "specific SOFT hints displaced the applicable HARD rule: $out" ;;
esac
n="$(printf '%s\n' "$out" | grep -c '^> Policy `vercel-soft-' || true)"
[ "$n" = 6 ] && ok "all 6 specific SOFT hints still shown" || bad "$n of 6 specific SOFT hints shown: $out"
n="$(bytes_of "$out")"
[ "$n" -lt 2000 ] && ok "fixture stays small ($n bytes)" || bad "unexpected fixture size: $n bytes"
# HARD rows are never capped; non-specific SOFT rows get only the slots left.
RF2="$(new_root hard-before-soft)"
for i in 1 2 3 4 5 6; do
  policy "$RF2" "aa-soft-$i" deploy soft "Soft deploy note $i."
done
for i in 1 2 3 4 5 6 7 8; do
  policy "$RF2" "zz-hard-$i" deploy hard "Hard deploy rule $i."
done
out="$(run "$RF2" sf2 'hq deploy' HQ_POLICY_GENERIC_CAP=0)"
n="$(printf '%s\n' "$out" | grep -c '^> Policy `zz-hard-' || true)"
[ "$n" = 8 ] && ok "all 8 HARD rows listed, over the cap of 6" || bad "$n of 8 HARD rows listed: $out"
case "$out" in
  *'> Policy `aa-soft-'*) bad "a non-specific SOFT row was shown with no slot left: $out" ;;
  *) ok "non-specific SOFT rows wait for a later event" ;;
esac
RF3="$(new_root hard-before-soft-default)"
for i in 1 2 3 4 5 6; do
  policy "$RF3" "aa-soft-$i" deploy soft "Soft deploy note $i."
done
for i in 1 2 3 4 5 6 7 8; do
  policy "$RF3" "zz-hard-$i" deploy hard "Hard deploy rule $i."
done
out="$(run "$RF3" sf3 'hq deploy')"
n="$(printf '%s\n' "$out" | grep -c '^> Policy `zz-hard-' || true)"
[ "$n" = 8 ] && ok "default generic cap: all 8 HARD rows on the common word are listed (HARD is never parked)" || bad "$n of 8 HARD rows under the default generic cap: $out"
[ "$(grep -c '^zz-hard-' "$RF3/workspace/orchestrator/policy-trigger-state/sf3.seen.tsv" 2>/dev/null || true)" = 0 ] \
  && ok "default generic cap: no HARD row is parked on the word" || bad "default generic cap: parked HARD rows: $(cat "$RF3/workspace/orchestrator/policy-trigger-state/sf3.seen.tsv" 2>/dev/null)"
case "$out" in
  *'> Policy `aa-soft-'*) bad "default generic cap: a SOFT row took a generic slot a HARD row needed: $out" ;;
  *) ok "default generic cap: SOFT one-word rows are parked" ;;
esac

# Malformed-trigger fallback rows did not match the event, so they never use
# a cap slot an applicable HARD rule needs.
RF3="$(new_root malformed-no-slot)"
for i in $(seq 1 10); do
  policy "$RF3" "broken-$i" 'deploy && (' hard "Fallback $i."
done
policy "$RF3" zz-approval deploy hard "Never ship without approval. APPROVAL_BODY"
out="$(run "$RF3" sf3 'hq deploy')"
case "$out" in
  *'> Policy `zz-approval` (HARD — binding rule from `'*APPROVAL_BODY*) ok "malformed fallback rows do not push the HARD rule out" ;;
  *) bad "malformed fallback rows crowded out the HARD rule: $out" ;;
esac
# An unparseable trigger did not match this tool call, so it is not shown on
# it at all (feedback_9eda6433): no fallback lines and no notice. The HARD
# rows still reach the enforcement set.
case "$out" in
  *'Malformed `when:` trigger'*|*'> Policy `broken-'*) bad "malformed fallback shown on an unrelated tool call: $out" ;;
  *) ok "malformed fallback rows are not shown on a tool call" ;;
esac
grep -q '^broken-1	' "$RF3/workspace/orchestrator/policy-enforcement/sf3.policies.tsv" 2>/dev/null \
  && ok "malformed HARD rows stay in the enforcement set" || bad "malformed HARD rows left the enforcement set"

echo "[e] SessionStart is not capped"
RE="$(new_root sessionstart)"
for i in $(seq -w 1 9); do
  policy "$RE" "baseline-$i" always soft "Baseline note $i." SessionStart
done
out="$(jq -cn '{session_id:"se",hook_event_name:"SessionStart",source:"startup",cwd:"/tmp"}' | hook "$RE")"
n="$(policy_lines "$out")"
[ "$n" = 9 ] && ok "all 9 baseline policies shown at SessionStart" || bad "SessionStart showed $n of 9: $out"

printf '\n%d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
