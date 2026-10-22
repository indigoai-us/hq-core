#!/usr/bin/env bash
# hq-core: public
# inject-policy-relevance-cap.test.sh
#
# Regression contract for feedback feedback_34ab4b26: the policy reminder
# matched 20+ policies per event, most on one common word, and cut every HARD
# rule but one to its summary line.
#   [a] 25 policies match; the 3 HARD rules with a specific match (two
#       identifiers, or one rare identifier) all print in full and rank
#       first, every other matched HARD rule is still listed, and only soft
#       rows are left out (PR #1526 review: the cap never drops a HARD rule).
#   [b] an event that matches only on one common word lists every HARD match
#       and at most the cap of soft rows; the soft rows left out stay
#       eligible for a later event.
#   [c] a HARD rule over the per-policy limit is still summarised with the
#       per-policy notice, even when its match is specific.
#   [d] over the output ceiling, soft lines go first; when full text still
#       does not fit, as many specific HARD rules as fit keep their text.
#   [e] SessionStart is not capped.
# 2026-10-21 (RC4 hook noise, stacked on #1526): on tool events at most
# HQ_POLICY_GENERIC_CAP (default 2) one-common-word matches are shown and the
# rest are parked on that word; a reactive HARD rule that loses the shared
# budget is deferred (no one-line summary). The pre-existing contracts are
# kept under HQ_POLICY_GENERIC_CAP=0 where they differ; the new defaults have
# their own file, inject-policy-generic-cap.test.sh.
#   [f] specific SOFT hints and malformed fallbacks never push an applicable
#       HARD rule out.
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

echo "[a] 25 matches: every specific HARD rule keeps its full text"
RA="$(new_root many)"
seed "$RA"
out="$(run "$RA" sa 'hq deploy vercel prod zebra-cluster')"
for s in vercel prod rare; do
  case "$out" in
    *'> Policy `zz-specific-'"$s"'` (HARD — binding rule from `'*) ok "specific HARD rule ($s) printed in full" ;;
    *) bad "specific HARD rule ($s) lost its full text: $out" ;;
  esac
done
n="$(full_count "$out")"
[ "$n" = 3 ] && ok "exactly the 3 specific HARD rules are in full" || bad "expected 3 full HARD bodies, found $n"
first3="$(slugs "$out" | head -3 | sort | tr '\n' ' ')"
[ "$first3" = "zz-specific-prod zz-specific-rare zz-specific-vercel " ] \
  && ok "specific HARD rules rank first" || bad "first three policies are: $first3"
# Every matched HARD rule is listed, including the 10 keyed on the common
# word `deploy`; only the 12 common-word soft rows are left out.
n="$(hard_named "$out" aa-common-hard-)"
[ "$n" = 10 ] && ok "all 10 common-word HARD rules are shown or named" || bad "$n of 10 common-word HARD rules shown or named: $out"
n="$(printf '%s\n' "$out" | grep -c '^> Policy `ab-common-soft-' || true)"
[ "$n" = 0 ] && ok "common-word soft rows are left out" || bad "$n common-word soft rows shown"
case "$out" in
  *'> Relevance cap 6: 12 lower-ranked soft matches not shown; every HARD match is shown or named above.'*) ok "relevance-cap notice counts the 12 soft rows left out" ;;
  *) bad "relevance-cap notice missing or wrong: $out" ;;
esac
case "$out" in
  *'> Policy `aa-common-hard-'*'[HARD · core]'*) bad "a common HARD rule was shortened to a one-line summary: $out" ;;
  *) ok "no common HARD rule is a one-line summary" ;;
esac
case "$out" in
  *'> Deferred, full-text budget of 5120 bytes spent: HARD policies `aa-common-hard-01`, `aa-common-hard-02`, '*'`aa-common-hard-10` are not shown as one-line summaries'*) ok "the common HARD rules that lost the budget are deferred by name" ;;
  *) bad "deferred notice missing or wrong: $out" ;;
esac
case "$out" in
  *'Output ceiling of'*) bad "the output ceiling was hit: $out" ;;
  *) ok "no output-ceiling fallback was needed" ;;
esac
n="$(bytes_of "$out")"
[ "$n" -le 8000 ] && ok "reminder within the 8000-byte ceiling ($n bytes)" || bad "reminder is $n bytes"
# Without the generic cap, the #1526 contract: six slots, 19 left out, still eligible.
RA0="$(new_root many-nocap)"
seed "$RA0"
out="$(run "$RA0" sa0 'hq deploy vercel prod zebra-cluster' HQ_POLICY_GENERIC_CAP=0)"
n="$(full_count "$out")"
[ "$n" = 3 ] && ok "generic cap off: the 3 specific HARD rules are in full" || bad "generic cap off: expected 3 full HARD bodies, found $n"
case "$out" in
  *'> Relevance cap 6: 12 lower-ranked soft matches not shown; every HARD match is shown or named above.'*) ok "generic cap off: relevance-cap notice counts the 12 soft rows left out" ;;
  *) bad "generic cap off: relevance-cap notice missing or wrong: $out" ;;
esac

# The shared full-text budget limits only less specific HARD rules.
RA2="$(new_root small-budget)"
seed "$RA2"
out="$(run "$RA2" sa2 'hq deploy vercel prod zebra-cluster' HQ_POLICY_HARD_BUDGET_BYTES=1500)"
n="$(full_count "$out")"
[ "$n" = 3 ] && ok "specific HARD rules stay in full under a 1500-byte budget" || bad "expected 3 full HARD bodies under a small budget, found $n: $out"

echo "[b] one common word: every HARD match listed, soft rows capped"
RB="$(new_root common)"
seed "$RB"
out="$(run "$RB" sb 'hq deploy')"
n="$(hard_named "$out" aa-common-hard-)"
[ "$n" = 10 ] && ok "all 10 HARD matches shown or named" || bad "$n of 10 HARD matches shown or named: $out"
n="$(printf '%s\n' "$out" | grep -c '^> Policy `ab-common-soft-' || true)"
[ "$n" -le 6 ] && ok "at most 6 soft rows ($n)" || bad "$n soft rows shown, over the cap of 6"
n="$(full_count "$out")"
[ "$n" -ge 2 ] && [ "$n" -le 4 ] && ok "HARD rules in full within the shared budget ($n bodies)" || bad "$n full HARD bodies for a common-word match, expected 2-4"
case "$out" in
  *'> Relevance cap 6: 12 lower-ranked soft matches not shown; every HARD match is shown or named above.'*) ok "notice counts the 12 soft rows left out" ;;
  *) bad "relevance-cap notice missing or wrong: $out" ;;
esac
n="$(bytes_of "$out")"
[ "$n" -le 8000 ] && ok "reminder within the 8000-byte ceiling ($n bytes)" || bad "reminder is $n bytes"
first="$(slugs "$out" | sort)"
again="$(run "$RB" sb 'hq deploy')"
case "$again" in
  *'> Policy `ab-common-soft-'*) bad "a parked soft row came back on the same word: $again" ;;
  *) ok "parked soft rows stay parked on the same word" ;;
esac
n="$(hard_named "$again" aa-common-hard-)"
[ "$n" -ge 1 ] && ok "deferred HARD rows come back on the next event ($n)" || bad "deferred HARD rows were lost: $again"
case "$again" in
  *'> Policy `aa-common-hard-01` (HARD'*|*'> Policy `aa-common-hard-02` (HARD'*) bad "a HARD row shown in full was repeated: $again" ;;
  *) ok "HARD rows already shown are not repeated" ;;
esac
# Without the generic cap, the #1526 contract: six slots, the rest eligible later.
RB1="$(new_root common-nocap)"
seed "$RB1"
out="$(run "$RB1" sb1 'hq deploy' HQ_POLICY_GENERIC_CAP=0)"
n="$(policy_lines "$out")"
[ "$n" -le 6 ] && ok "generic cap off: single common word shows $n policies (cap 6)" || bad "generic cap off: single common word shows $n policies"
n="$(full_count "$out")"
[ "$n" -le 4 ] && ok "generic cap off: full text stays within the shared budget ($n bodies)" || bad "generic cap off: $n full HARD bodies for a common-word match"
case "$out" in
  *'> Relevance cap 6: 12 lower-ranked soft matches not shown; every HARD match is shown or named above.'*) ok "generic cap off: notice counts the 12 soft rows left out" ;;
  *) bad "generic cap off: relevance-cap notice missing or wrong: $out" ;;
esac
first="$(slugs "$out" | sort)"
again="$(run "$RB1" sb1 'hq deploy' HQ_POLICY_GENERIC_CAP=0)"
second="$(slugs "$again" | sort)"
[ -n "$second" ] && [ -z "$(comm -12 <(printf '%s\n' "$first") <(printf '%s\n' "$second"))" ] \
  && ok "generic cap off: rows left out come back on a later event, without repeats" \
  || bad "generic cap off: second event repeated or lost rows: first=[$first] second=[$second]"
out="$(run "$RB" sb0 'hq deploy' HQ_POLICY_RELEVANCE_CAP=0)"
case "$out" in
  *'Relevance cap'*) bad "HQ_POLICY_RELEVANCE_CAP=0 still capped: $out" ;;
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
full="$(run "$RD" sd0 'hq deploy vercel prod zebra-cluster')"
full_bytes="$(bytes_of "$full")"
case "$full" in
  *'> Policy `ac-specific-soft-'*'> Deferred, full-text budget of 5120 bytes spent: HARD policies `aa-common-hard-1`, `aa-common-hard-2`'*) ok "fixture: soft lines are shown and the two common HARD rules are deferred, not summarised" ;;
  *) bad "fixture ordering unexpected: $full" ;;
esac
# Room for the cut notice, minus about two soft lines.
ceiling=$((full_bytes - 200))
out="$(run "$RD" sd 'hq deploy vercel prod zebra-cluster' HQ_POLICY_OUTPUT_CEILING_BYTES=$ceiling)"
n="$(bytes_of "$out")"
[ "$n" -le "$ceiling" ] && ok "reminder within the $ceiling-byte ceiling ($n bytes)" || bad "reminder is $n bytes, over $ceiling"
n="$(full_count "$out")"
[ "$n" = 3 ] && ok "all 3 specific HARD rules kept in full once soft lines are cut" || bad "expected 3 full bodies, found $n: $out"
case "$out" in
  *'lower-ranked policy line(s) cut from this reminder'*) ok "notice says lines were cut" ;;
  *) bad "no cut notice: $out" ;;
esac
soft_left="$(printf '%s\n' "$out" | grep -c '^> Policy `ac-specific-soft-' || true)"
hard_left="$(printf '%s\n' "$out" | grep -c '^> Policy `aa-common-hard-.*\[HARD · core\]' || true)"
[ "$soft_left" -lt 3 ] && [ "$hard_left" = 0 ] \
  && ok "soft lines were cut and no HARD rule became a one-line summary" \
  || bad "expected soft lines cut and no HARD summaries (soft=$soft_left hard=$hard_left): $out"
out="$(run "$RD" sd2 'hq deploy vercel prod zebra-cluster' HQ_POLICY_OUTPUT_CEILING_BYTES=3600)"
n="$(bytes_of "$out")"
[ "$n" -le 3600 ] && ok "reminder within the 3600-byte ceiling ($n bytes)" || bad "reminder is $n bytes, over 3600"
n="$(full_count "$out")"
[ "$n" = 2 ] && ok "two specific HARD rules kept in full under a tighter ceiling" || bad "expected 2 full bodies, found $n: $out"
case "$out" in
  *'HARD policies `zz-specific-'*'`, `zz-specific-'*'` keep their full text as the top-ranked matches'*) ok "notice names both kept rules" ;;
  *) bad "keep notice missing: $out" ;;
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
[ "$n" = 8 ] && ok "default generic cap: every HARD row is kept, never parked" || bad "$n of 8 HARD rows under the default generic cap: $out"
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
case "$out" in
  *'Malformed `when:` trigger'*'lint-policy-triggers.sh'*) ok "malformed notice still delivered under the cap" ;;
  *) bad "malformed notice missing under the cap: $out" ;;
esac

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
