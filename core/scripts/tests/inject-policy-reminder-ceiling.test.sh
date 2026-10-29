#!/usr/bin/env bash
# hq-core: public
# inject-policy-reminder-ceiling.test.sh
#
# Regression contract for the reminder-ceiling design (indigo feedback-zero,
# cluster policy-reminder-ceiling, 2026-10-22): the same HARD summary lines
# repeated on every tool call, 8000 bytes per call, ranked by filename.
# One case per ledger shape; every case fails against the hook on main.
#   [1] shapes 1 and 4, repeat loop: three identical events, 12 HARD rules on
#       `git`. No slug is listed as its own line more than once per session;
#       later events name it only in the footer.
#   [2] shape 2, tail drain: rows the ceiling cuts are never recorded (they
#       were not delivered); they are listed on the next event once the
#       delivered rows have moved to the footer, every HARD rule is delivered
#       once within a few events, and the output then shrinks to the footer.
#   [3] shape 3, ranking: a HARD rule matching a path token and a rare word
#       outranks one matching the head word and a common word, regardless of
#       scope and filename order, and takes the full-text slot.
#   [4] shape 6, common-word HARD: a HARD rule matching only a word used by
#       over 20 percent of the in-scope policies is listed at most up to the
#       generic cap and parked; a HARD rule matching the head word is listed.
#   [5] shape 1, no mid-text cut: a 300-byte rule line is cut at a word
#       boundary with an ellipsis; a body over the per-policy limit falls to
#       its Rule section, never to a prefix of the body.
#   [6] shape 5, budget: 30 HARD and 40 soft matches emit at most 4000 bytes
#       of context, and the stdout JSON parses.
#   [7] footer: a HARD rule shown in full on event 1 is named in the
#       "Already shown" footer on event 2, not as a body or a summary line.
# HOOK (or HQ_TEST_INJECT_POLICY_HOOK) points the run at another copy of the
# hook, e.g. the main branch extracted beside a copy of core/scripts.
set -euo pipefail
# These fixtures use common verbs (deploy, run, release) as neutral vehicle
# words for the cap and ceiling mechanics. The tool-event subject filter
# (feedback_9eda6433) would treat them as generic words and keep them off the
# tool call, so it is switched off here; inject-policy-tool-subject-match.test.sh
# covers the filter itself.
export HQ_POLICY_TOOL_STOP_WORDS=

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${HOOK:-${HQ_TEST_INJECT_POLICY_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}}"
FACT_LIB="$ROOT/core/scripts/lib/trigger-fact-text.awk"
command -v jq >/dev/null || { echo "jq required"; exit 2; }
[ -r "$FACT_LIB" ] || { echo "missing $FACT_LIB"; exit 2; }
[ -r "$HOOK" ] || { echo "missing hook $HOOK"; exit 2; }

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
  mkdir -p "$dir/core/policies" "$dir/companies/acme/policies" "$dir/workspace/orchestrator/policy-trigger-state"
  printf '%s' "$dir"
}
policy() { # <dir> <id> <when> <enforcement> <body-after-## Rule heading>
  printf -- '---\nid: %s\nwhen: %s\non: [PreToolUse, PostToolUse, UserPromptSubmit]\nenforcement: %s\n---\n\n## Rule\n\n%s\n' \
    "$2" "$3" "$4" "$5" > "$1/$2.md"
}
# raw <root> <sid> <command> [env...] — stdout of a Bash PostToolUse event.
raw() {
  local root="$1" sid="$2" command="$3"
  shift 3
  jq -cn --arg sid "$sid" --arg command "$command" \
    '{session_id:$sid,hook_event_name:"PostToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:$command},tool_response:{stdout:"ok",stderr:""}}' \
    | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" "$@" bash "$HOOK" 2>/dev/null || true
}
# run <root> <sid> <command> [env...] — the reminder text of that event.
run() { raw "$@" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true; }
bytes_of() { printf '%s' "$1" | wc -c | tr -d ' '; }
line_slugs() { printf '%s\n' "$1" | sed -n 's/^> Policy `\([^`]*\)`.*/\1/p'; }
full_slugs() { printf '%s\n' "$1" | sed -n -e 's/^> Policy `\([^`]*\)` (HARD — binding rule from .*/\1/p' -e 's/^> Policy `\([^`]*\)` (HARD — Rule section from .*/\1/p'; }
seen_file() { printf '%s/workspace/orchestrator/policy-trigger-state/%s.seen.tsv' "$1" "$2"; }
ledger_file() { printf '%s/workspace/orchestrator/policy-trigger-state/%s.txt' "$1" "$2"; }

FILLER="$(printf 'filler text for the body %.0s' $(seq 1 50))"   # ~1.25 KB, under the 2 KB per-policy limit

echo "[1] shapes 1 and 4: the repeat loop stops after one listing per slug"
R1="$(new_root repeat)"
for i in $(seq -w 1 12); do
  policy "$R1/core/policies" "git-hard-$i" git hard "Git rule $i. GIT_BODY_$i $FILLER"
done
o1="$(run "$R1" s1 'git status --short')"
o2="$(run "$R1" s1 'git status --short')"
o3="$(run "$R1" s1 'git status --short')"
[ -n "$o1" ] && ok "first event emits a reminder" || bad "first event emitted nothing"
[ "$(full_slugs "$o1" | wc -l | tr -d ' ')" -ge 1 ] && ok "first event shows a HARD rule in full" || bad "no full HARD body on the first event: $o1"
in_all=0
for i in $(seq -w 1 12); do
  if line_slugs "$o1" | grep -qx "git-hard-$i" && line_slugs "$o2" | grep -qx "git-hard-$i" && line_slugs "$o3" | grep -qx "git-hard-$i"; then
    in_all=$((in_all + 1))
  fi
done
[ "$in_all" -eq 0 ] && ok "no slug is listed as its own line in all three events" || bad "$in_all slugs are listed as lines in all three events"
dup=0
for i in $(seq -w 1 12); do
  n="$( { line_slugs "$o1"; line_slugs "$o2"; line_slugs "$o3"; } | grep -cx "git-hard-$i" || true)"
  [ "$n" -le 1 ] || dup=$((dup + 1))
done
[ "$dup" -eq 0 ] && ok "no slug is listed as its own line more than once in the session" || bad "$dup slugs were listed as lines more than once"
for ev in "$o2" "$o3"; do
  case "$ev" in
    *'> Already shown this session, still binding: '*'git-hard-01'*) ok "later event names the rule shown in full only in the footer" ;;
    *) bad "later event lacks the footer naming git-hard-01: $ev" ;;
  esac
done
[ -z "$(line_slugs "$o3")" ] && ok "once every rule has been delivered the event is footer-only" || bad "third event still lists rows: $(line_slugs "$o3" | tr '\n' ' ')"
[ "$(bytes_of "$o3")" -lt 1000 ] && ok "a footer-only event is small ($(bytes_of "$o3") bytes)" || bad "footer-only event is $(bytes_of "$o3") bytes"

echo "[2] shape 2: the tail cut by the ceiling drains instead of returning"
R2="$(new_root drain)"
for i in $(seq -w 1 12); do
  policy "$R2/core/policies" "git-hard-$i" git hard "Git rule $i. GIT_BODY_$i $FILLER"
done
policy "$R2/core/policies" zz-git-or-gh 'git || gh' hard "Git or gh rule. GIT_OR_GH_BODY $FILLER"
# Summaries only, under a ceiling that fits about four lines.
small=(HQ_POLICY_HARD_FULL_TEXT=0 HQ_POLICY_OUTPUT_CEILING_BYTES=1200)
d1="$(run "$R2" s2 'git status --short' "${small[@]}")"
listed1="$(line_slugs "$d1")"
n1="$(printf '%s\n' "$listed1" | grep -c . || true)"
[ "$n1" -ge 1 ] && [ "$n1" -lt 13 ] && ok "first event lists $n1 of 13 rules; the rest are cut" || bad "fixture did not cut: $n1 lines"
case "$d1" in *'lower-ranked policy line(s) held for a later call'*) ok "cut notice says the lines are held for a later call" ;; *) bad "no cut notice: $d1" ;; esac
# A cut row was never delivered: it is in neither ledger.
cut_recorded=0
for i in $(seq -w 1 12); do
  printf '%s\n' "$listed1" | grep -x "git-hard-$i" >/dev/null && continue
  grep -q "^git-hard-$i	" "$(seen_file "$R2" s2)" 2>/dev/null && cut_recorded=$((cut_recorded + 1))
  grep -qx "git-hard-$i" "$(ledger_file "$R2" s2)" 2>/dev/null && cut_recorded=$((cut_recorded + 1))
done
[ "$cut_recorded" -eq 0 ] && ok "no cut row is recorded in the seen set or the session ledger" || bad "$cut_recorded cut rows were recorded: $(cat "$(seen_file "$R2" s2)" 2>/dev/null)"
# The rows that were listed are recorded as delivered (with full text off a
# summary line is the most a rule can get, so the session ledger holds them).
listed_recorded=0
for s in $listed1; do grep -qx "$s" "$(ledger_file "$R2" s2)" 2>/dev/null && listed_recorded=$((listed_recorded + 1)); done
[ "$listed_recorded" -eq "$n1" ] && ok "every listed line is recorded as delivered ($listed_recorded)" || bad "$listed_recorded of $n1 listed rows recorded: $(cat "$(ledger_file "$R2" s2)" 2>/dev/null)"
d2="$(run "$R2" s2 'git status --short' "${small[@]}")"
listed2="$(line_slugs "$d2")"
[ -n "$listed2" ] && ok "second event lists the rows cut on the first" || bad "second event listed nothing: $d2"
overlap=0
for s in $listed2; do printf '%s\n' "$listed1" | grep -x "$s" >/dev/null && overlap=$((overlap + 1)); done
[ "$overlap" -eq 0 ] && ok "second event repeats none of the first event's rows" || bad "$overlap rows repeated: $listed2"
case "$d2" in *'> Already shown this session, still binding: '*) ok "second event names the delivered rows in the footer" ;; *) bad "second event lacks the footer: $d2" ;; esac
# Enough events with the same command deliver every HARD rule once; after
# that the output is footer-only.
delivered="$listed1"$'\n'"$listed2"
footer_only=""
for ev in 3 4 5 6 7 8; do
  dn="$(run "$R2" s2 'git status --short' "${small[@]}")"
  ln="$(line_slugs "$dn")"
  if [ -z "$ln" ]; then footer_only="$ev"; case "$dn" in *'> Already shown this session, still binding: '*) ;; *) bad "footer-only event $ev lacks the footer: $dn" ;; esac; break; fi
  for s in $ln; do printf '%s\n' "$delivered" | grep -x "$s" >/dev/null && bad "$s delivered twice (event $ev)"; done
  delivered="$delivered"$'\n'"$ln"
done
missing=""
for i in $(seq -w 1 12); do printf '%s\n' "$delivered" | grep -x "git-hard-$i" >/dev/null || missing="$missing git-hard-$i"; done
printf '%s\n' "$delivered" | grep -x zz-git-or-gh >/dev/null || missing="$missing zz-git-or-gh"
[ -z "$missing" ] && ok "every HARD rule was delivered once over the drain" || bad "never delivered:$missing"
[ -n "$footer_only" ] && ok "the output shrank to footer-only at event $footer_only" || bad "the output never became footer-only"
# Footer-only repeat: the same footer on the next event
# carries no new rule, so the hook emits nothing; the opt-out restores it.
drep="$(run "$R2" s2 'git status --short' "${small[@]}")"
[ -z "$drep" ] && ok "an identical footer-only reminder is not repeated" || bad "footer-only reminder repeated: $drep"
drep_on="$(run "$R2" s2 'git status --short' "${small[@]}" HQ_POLICY_FOOTER_REPEAT=1)"
case "$drep_on" in *'> Already shown this session, still binding: '*) ok "HQ_POLICY_FOOTER_REPEAT=1 restores the repeated footer" ;; *) bad "opt-out did not restore the footer: $drep_on" ;; esac
grep -qx 'git-hard-01' "$(ledger_file "$R2" s2)" && ok "suppressing the footer leaves the session ledger intact" || bad "session ledger lost git-hard-01"
d3="$(run "$R2" s2 'gh pr view 12' "${small[@]}")"
case "$d3" in *'> Policy `'*) bad "a different trigger (gh) re-listed a delivered rule: $d3" ;; *) ok "a different trigger (gh) lists no delivered rule again" ;; esac
case "$d3" in *'> Already shown this session, still binding: zz-git-or-gh.'*) ok "and names only the rule that matches gh in the footer" ;; *) bad "footer for gh wrong: $d3" ;; esac

echo "[3] shape 3: the score decides the full-text slot, not scope or filename"
R3="$(new_root ranking)"
# `test` is common here (9 of 10 in-scope policies use it); `vitest` is rare;
# `.ts` is a path token; `pnpm` is the head word. The company rule sorts
# first by scope and by name on main.
policy "$R3/companies/acme/policies" bb-test-rule 'pnpm && test' hard "Run the suite before pushing. TEST_RULE_BODY $FILLER"
policy "$R3/core/policies" zz-vitest-rule 'vitest && .ts' hard "Vitest files need the acl fixture. VITEST_RULE_BODY $FILLER"
for i in $(seq 1 8); do
  policy "$R3/core/policies" "aa-test-note-$i" test soft "Test note $i."
done
o="$(run "$R3" s3 'pnpm vitest src/acl/permission.test.ts' HQ_POLICY_COMPANY=acme)"
first="$(line_slugs "$o" | head -1)"
[ "$first" = zz-vitest-rule ] && ok "the path-and-rare-word rule ranks first" || bad "first policy is $first, not zz-vitest-rule: $o"
case "$o" in *'> Policy `zz-vitest-rule` (HARD — binding rule from `'*VITEST_RULE_BODY*) ok "the top-ranked rule has the full-text slot" ;; *) bad "zz-vitest-rule not in full: $o" ;; esac
case "$o" in *'`bb-test-rule`'*) ok "the head-word rule is still listed" ;; *) bad "bb-test-rule missing: $o" ;; esac

echo "[4] shape 6: a HARD rule on a common word is listed, never parked"
R4="$(new_root common)"
for i in 1 2 3 4 5; do
  policy "$R4/core/policies" "run-hard-$i" run hard "Run rule $i. RUN_BODY_$i $FILLER"
done
policy "$R4/core/policies" pnpm-hard pnpm hard "pnpm rule. PNPM_BODY $FILLER"
for i in 1 2 3 4 5 6; do
  policy "$R4/core/policies" "docker-note-$i" docker soft "Docker note $i."
done
o="$(run "$R4" s4 'pnpm run build')"
n="$(line_slugs "$o" | grep -c '^run-hard-' || true)"
[ "$n" = 5 ] && ok "every common-word HARD rule is listed (5 of 5; HARD is never parked)" || bad "$n run-hard rules listed, expected 5: $o"
parked="$(grep -c '^run-hard-' "$(seen_file "$R4" s4)" 2>/dev/null || true)"
[ "${parked:-0}" = 0 ] && ok "no common-word HARD rule is parked in the seen set" || bad "parked run-hard rows: $parked, expected 0"
case "$o" in *'> Policy `pnpm-hard` (HARD — binding rule from `'*PNPM_BODY*) ok "the head-word HARD rule is listed in full" ;; *) bad "pnpm-hard not in full: $o" ;; esac
case "$o" in *'> Skipped:'*) bad "a skip notice was printed with nothing parked: $o" ;; *) ok "no skip notice: nothing was parked" ;; esac

echo "[5] shape 1: no mid-text cut"
R5="$(new_root nocut)"
# 30 nine-letter words: byte 157 falls inside a word on the old cut.
long_rule="$(printf 'wordabcde %.0s' $(seq 1 30))"
long_rule="${long_rule% }"
policy "$R5/core/policies" long-line deploy hard "$long_rule"
o="$(run "$R5" s5 'deploy prod' HQ_POLICY_HARD_FULL_TEXT=0)"
summary="$(printf '%s\n' "$o" | sed -n 's/^> Policy `long-line` applies here: \(.*\)  \[HARD · core\].*/\1/p')"
[ -n "$summary" ] && ok "summary line present" || bad "no summary line for long-line: $o"
case "$summary" in *...) ok "summary ends with an ellipsis" ;; *) bad "summary does not end with an ellipsis: $summary" ;; esac
kept="${summary%...}"
next_char="${long_rule:${#kept}:1}"
[ "${#kept}" -lt 160 ] && ok "summary is under 160 bytes before the ellipsis (${#kept})" || bad "summary is ${#kept} bytes"
case "$long_rule" in "$kept"*) ok "the kept text is a prefix of the rule" ;; *) bad "kept text is not a prefix: $kept" ;; esac
case "${kept: -1}" in [a-z0-9]) ;; *) bad "kept text ends in a separator, not a word: '$kept'" ;; esac
case "$next_char" in ' '|'') ok "the cut falls on a word boundary" ;; *) bad "the cut splits a word (next char '$next_char'): $kept" ;; esac
R5B="$(new_root nocut-body)"
scope_text="$(printf 'scope detail %.0s' $(seq 1 180))"   # ~2.3 KB of non-Rule text
policy "$R5B/core/policies" long-tail deploy hard "Check the team before a deploy. RULE_ONLY_BODY"$'\n\n## Scope\n\n'"$scope_text SCOPE_MARKER"
o="$(run "$R5B" s5b 'deploy prod')"
case "$o" in
  *'> Policy `long-tail` (HARD — Rule section from `'*RULE_ONLY_BODY*) ok "an oversized body falls to its whole Rule section" ;;
  *'> Policy `long-tail` applies here:'*) ok "an oversized body falls to its summary line" ;;
  *) bad "oversized body neither Rule section nor summary: $o" ;;
esac
case "$o" in *'scope detail'*) bad "a prefix of the body was printed: $o" ;; *) ok "no prefix of the body is printed" ;; esac

echo "[6] shape 5: 30 HARD and 40 soft matches stay within 4000 bytes"
R6="$(new_root budget)"
for i in $(seq -w 1 30); do policy "$R6/core/policies" "hard-deploy-$i" deploy hard "Deploy rule $i. DEPLOY_BODY_$i $FILLER"; done
for i in $(seq -w 1 40); do policy "$R6/core/policies" "soft-deploy-$i" deploy soft "Soft deploy note $i."; done
out="$(raw "$R6" s6 'deploy prod')"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 && ok "stdout JSON parses" || bad "stdout is not a valid envelope: $out"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
n="$(bytes_of "$ctx")"
[ "$n" -le 4000 ] && [ "$n" -gt 0 ] && ok "context is $n bytes, within 4000" || bad "context is $n bytes"
n="$(bytes_of "$out")"
[ "$n" -le 4000 ] && ok "stdout envelope is $n bytes, within 4000" || bad "stdout envelope is $n bytes"
[ "$(full_slugs "$ctx" | wc -l | tr -d ' ')" -ge 1 ] && ok "one HARD rule is still shown in full" || bad "no full HARD body: $ctx"

echo "[7] footer: a HARD rule shown in full is named, not repeated"
R7="$(new_root footer)"
policy "$R7/core/policies" zz-deploy-prod 'deploy && prod' hard "NEVER deploy to prod without the checklist. PROD_BODY $FILLER"
policy "$R7/core/policies" soft-deploy deploy soft "Soft deploy note."
f1="$(run "$R7" s7 'hq deploy prod')"
case "$f1" in *'> Policy `zz-deploy-prod` (HARD — binding rule from `'*PROD_BODY*) ok "event 1 shows the rule in full" ;; *) bad "event 1 did not show the rule in full: $f1" ;; esac
f2="$(run "$R7" s7 'hq deploy prod')"
case "$f2" in *'> Policy `zz-deploy-prod`'*) bad "event 2 repeated the rule as a line: $f2" ;; *) ok "event 2 has no body and no summary line for the rule" ;; esac
case "$f2" in *PROD_BODY*) bad "event 2 repeated the body" ;; *) ok "event 2 does not repeat the body" ;; esac
case "$f2" in *'> Already shown this session, still binding: zz-deploy-prod.'*) ok "event 2 names the rule in the footer" ;; *) bad "event 2 footer missing: $f2" ;; esac

echo "[8] no valid HARD match is parked, unlisted or unnamed"
R8="$(new_root parked-named)"
for i in 1 2 3 4 5; do
  policy "$R8/core/policies" "run-hard-$i" run hard "Run rule $i. RUN_BODY_$i $FILLER"
done
policy "$R8/core/policies" pnpm-hard pnpm hard "pnpm rule. PNPM_BODY $FILLER"
for i in 1 2 3 4 5 6; do
  policy "$R8/core/policies" "docker-note-$i" docker soft "Docker note $i."
done
o="$(run "$R8" s8 'pnpm run build')"
case "$o" in *'HARD among them'*) bad "a HARD rule was parked: $o" ;; *) ok "no HARD rule is parked" ;; esac
unnamed=""
for s in run-hard-1 run-hard-2 run-hard-3 run-hard-4 run-hard-5 pnpm-hard; do
  case "$o" in *"$s"*) ;; *) unnamed="$unnamed $s" ;; esac
done
[ -z "$unnamed" ] && ok "every valid HARD match is listed or named somewhere in the reminder" || bad "HARD matches neither listed nor named:$unnamed"

echo "[9] two or more common identifiers still score above zero"
R9="$(new_root two-common)"
for i in 1 2 3; do
  policy "$R9/core/policies" "deploy-prod-$i" 'deploy && prod' hard "Deploy to prod rule $i. DP_BODY_$i $FILLER"
done
for i in 1 2 3 4 5 6; do
  policy "$R9/core/policies" "deploy-note-$i" deploy soft "Deploy note $i."
  policy "$R9/core/policies" "prod-note-$i" prod soft "Prod note $i."
done
o="$(run "$R9" s9 'hq deploy prod')"
n="$(line_slugs "$o" | grep -c '^deploy-prod-' || true)"
[ "$n" = 3 ] && ok "all three deploy && prod HARD rules are listed (not parked as generic)" || bad "$n of 3 listed: $o"
case "$o" in *'HARD among them'*) bad "a deploy && prod rule was parked as generic: $o" ;; *) ok "none of them is parked by the generic cap" ;; esac

echo "[10] the one-line count stays true when the trim cuts an oversize line"
R10="$(new_root trim-oversize)"
for i in 1 2 3 4 5 6; do
  policy "$R10/core/policies" "aa-deploy-$i" deploy hard "Deploy rule $i. DEPLOY_BODY_$i $FILLER"
done
huge="$(printf 'rule text %.0s' $(seq 1 260))"   # ~2.6 KB inside ## Rule: over the per-policy limit
policy "$R10/core/policies" zz-oversize deploy hard "Huge rule. HUGE_BODY $huge"
o="$(run "$R10" s10 'deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES=1700)"
[ "$(bytes_of "$o")" -le 1700 ] && ok "reminder within the 1700-byte ceiling" || bad "reminder is $(bytes_of "$o") bytes"
case "$o" in *'held for a later call'*) ok "the ceiling cut lines" ;; *) bad "fixture did not trim: $o" ;; esac
over_slugs="$(printf '%s\n' "$o" | sed -n 's/^> Over the [0-9]*-byte per-policy limit, so shortened to one-line summaries — \(.*\)\. Read each.*/\1/p' | tr -d ',')"
surviving=0
for s in $(printf '%s\n' "$o" | sed -n 's/^> Policy `\([^`]*\)` applies here: .* \[HARD · .*/\1/p'); do
  case " $over_slugs " in *" $s "*) ;; *) surviving=$((surviving + 1)) ;; esac
done
counted="$(printf '%s\n' "$o" | sed -n 's/^> Output budget [0-9]* bytes: \([0-9]*\) HARD polic.* listed as one line.*/\1/p')"
[ -z "$counted" ] && counted=0
[ "$counted" = "$surviving" ] && ok "the budget notice counts the surviving one-line HARD rules ($counted)" || bad "budget notice says $counted, surviving one-line HARD rules: $surviving: $o"

printf '\n%d passed, %d failed\n' "$passes" "$failures"
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures"
  exit 1
fi
echo "PASS"
