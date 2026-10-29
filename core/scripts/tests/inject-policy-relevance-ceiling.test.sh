#!/usr/bin/env bash
# hq-core: public
# inject-policy-relevance-ceiling.test.sh
#
# Regression contract for feedback a2b3bfef: the policy reminder hit its byte
# ceiling and cut policies, shortening every HARD rule to one line and dropping
# lower-ranked ones.
#   [a] a trigger that matches many policies keeps the most relevant HARD rule
#       (a direct `when:` match on the command) in full; the generic matches
#       are summarised and the "read the file" pointer stays.
#   [b] a HARD rule shown only as a summary is parked in the seen set: it is
#       not repeated for the same trigger inside the window (the footer names
#       it), and it comes back in full on a new trigger or once the window
#       expires (reminder-ceiling design, 2026-10-22).
#   [c] output never exceeds the configured ceiling, for plain stdout and for
#       the PostToolUse JSON envelope.
set -euo pipefail
# These fixtures use common verbs (deploy, run, release) as neutral vehicle
# words for the cap and ceiling mechanics. The tool-event subject filter
# (feedback_9eda6433) would treat them as generic words and keep them off the
# tool call, so it is switched off here; inject-policy-tool-subject-match.test.sh
# covers the filter itself.
export HQ_POLICY_TOOL_STOP_WORDS=

# This file tests the byte ceiling and full-text fallback on their own, with
# fixtures that match many policies at once. The per-event relevance cap would
# hide most of them, so it is off here; inject-policy-relevance-cap.test.sh
# covers the cap and its interaction with the ceiling.
export HQ_POLICY_RELEVANCE_CAP=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${HQ_TEST_INJECT_POLICY_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
FACT_LIB="$ROOT/core/scripts/lib/trigger-fact-text.awk"
command -v jq >/dev/null || { echo "jq required"; exit 2; }
[ -r "$FACT_LIB" ] || { echo "missing $FACT_LIB"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Stand-in for `hq core derive-trigger-facts`: the per-event source text
# (PreToolUse -> command, PostToolUse -> tool output) tokenized by the real
# shared fact library.
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
policy() { # <root> <id> <when> <enforcement> <rule>
  printf -- '---\nid: %s\nwhen: %s\non: [PreToolUse, PostToolUse, UserPromptSubmit]\nenforcement: %s\n---\n\n## Rule\n\n%s\n' \
    "$2" "$3" "$4" "$5" > "$1/core/policies/$2.md"
}
prompt() { # <root> <sid> <prompt> [env...]
  local root="$1" sid="$2" text="$3"
  shift 3
  jq -cn --arg sid "$sid" --arg prompt "$text" \
    '{session_id:$sid,hook_event_name:"UserPromptSubmit",cwd:"/tmp",prompt:$prompt}' \
    | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" \
      "$@" bash "$HOOK" 2>/dev/null
}
# HQ_POLICY_TOOL_BASELINE=1: the fixture uses `when: always` HARD rules as the
# low-ranked bulk that the ceiling must cut and drain. Since feedback_9eda6433
# such rules are not shown on tool events by default (see
# inject-policy-tool-relevance.test.sh); this test pins the ceiling and drain
# mechanics, so it keeps them in the tool-event reminder.
post() { # <root> <sid> <command> <tool-output> [env...]
  local root="$1" sid="$2" command="$3" response="$4"
  shift 4
  jq -cn --arg sid "$sid" --arg command "$command" --arg response "$response" \
    '{session_id:$sid,hook_event_name:"PostToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:$command},tool_response:{stdout:$response,stderr:""}}' \
    | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" \
      HQ_POLICY_TOOL_BASELINE=1 "$@" bash "$HOOK" 2>/dev/null
}
context() { jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true; }
# Reminder text for a Bash PostToolUse. Passive PreToolUse stdout is not model
# context, so the command-keyed (PreToolUse) facts are exercised through
# PostToolUse, which evaluates them for policies that also list PreToolUse.
run() { # <root> <sid> <command> [env...]
  local root="$1" sid="$2" command="$3"
  shift 3
  post "$root" "$sid" "$command" 'ok' "$@" | context
}
bytes_of() { printf '%s\n' "$1" | wc -c | tr -d ' '; }

# Fixture: six generic HARD rules (`when: always`) that sort ahead of the
# direct rules by name, two direct HARD rules keyed on the command, and a few
# soft rules. Each HARD body is ~1.3 KB, under the 2 KB per-policy limit, so
# full text for all of them is far over a 3000-byte ceiling.
seed() {
  local root="$1" i filler
  filler="$(printf 'filler text for the body %.0s' $(seq 1 50))"
  for i in 1 2 3 4 5 6; do
    policy "$root" "aaa-generic-$i" always hard "ALWAYS generic rule $i. GENERIC_BODY_$i $filler"
  done
  policy "$root" zz-deploy-direct 'deploy && prod' hard "NEVER deploy to prod without the checklist. DIRECT_BODY $filler"
  policy "$root" yy-release-rule 'deploy || release' hard "ALWAYS tag the release first. RELEASE_BODY $filler"
  for i in 1 2 3; do
    policy "$root" "soft-$i" deploy soft "Soft deploy note $i."
  done
}

echo "[0] default routing: the ceiling holds, the direct rules drain, the always bulk is not repeated"
R0="$(new_root default-routing)"
seed "$R0"
d_all=""
for i in 1 2 3 4; do
  o="$(post "$R0" s0 'hq deploy prod' ok HQ_POLICY_TOOL_BASELINE=0 HQ_POLICY_OUTPUT_CEILING_BYTES=3000 | context)"
  n="$(bytes_of "$o")"
  [ "$n" -le 3000 ] && ok "default event $i within the 3000-byte ceiling ($n bytes)" || bad "default event $i is $n bytes"
  d_all="$d_all"$'\n'"$(printf '%s\n' "$o" | sed -n 's/^> Policy `\([^`]*\)`.*/\1/p')"
done
for slug in zz-deploy-direct yy-release-rule; do
  printf '%s\n' "$d_all" | grep -x "$slug" >/dev/null && ok "default routing delivers $slug" || bad "default routing never delivered $slug"
done
# Owner decision on #1688: an unconditional rule prints on its first tool-event
# match in a session, and is never listed again on a later tool event.
for i in 1 2 3 4 5 6; do
  n="$(printf '%s\n' "$d_all" | grep -cx "aaa-generic-$i" || true)"
  [ "$n" -le 1 ] && ok "default routing lists aaa-generic-$i at most once ($n)" || bad "aaa-generic-$i listed $n times"
done

echo "[a] the most relevant HARD rule keeps its full text"
RA="$(new_root keep-top)"
seed "$RA"
out="$(run "$RA" sa 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES=3000)"
listed_a="$(printf '%s\n' "$out" | sed -n 's/^> Policy `\([^`]*\)`.*/\1/p')"
n="$(bytes_of "$out")"
[ "$n" -le 3000 ] && ok "reminder within the 3000-byte ceiling ($n bytes)" || bad "reminder is $n bytes, over 3000"
case "$out" in
  *'> Policy `zz-deploy-direct` (HARD — binding rule from `'*'DIRECT_BODY'*) ok "direct HARD match kept in full" ;;
  *) bad "direct HARD match lost its full text: $out" ;;
esac
full_count="$(grep -c '(HARD — binding rule from `' <<<"$out" || true)"
[ "$full_count" = 1 ] && ok "lower-ranked HARD rules are not in full" \
  || bad "expected one full HARD body, found $full_count: $out"
case "$out" in
  *'HARD policy `zz-deploy-direct` keeps its full text as the top-ranked match'*'Read a listed rule at its file now'*) ok "notice names the kept rule and keeps the read-the-file pointer" ;;
  *'> Output budget 3000 bytes: '*' HARD policies listed as one line.'*) ok "the full-text budget alone listed the other HARD rules as one line" ;;
  *) bad "neither the ceiling notice nor the budget notice is present: $out" ;;
esac
case "$out" in
  *'> Policy `yy-release-rule` applies here:'*) ok "second direct HARD rule is summarised" ;;
  *) bad "second direct HARD rule missing as a summary: $out" ;;
esac
first="$(printf '%s\n' "$out" | sed -n 's/^> Policy `\([^`]*\)`.*/\1/p' | head -1)"
[ "$first" = zz-deploy-direct ] && ok "direct HARD match ranks first" || bad "first policy is $first, not zz-deploy-direct"

# Without ceiling pressure the direct rule still ranks ahead of the generic
# HARD rules and so claims the full-text budget first.
RA2="$(new_root rank-only)"
seed "$RA2"
out="$(run "$RA2" sa2 'hq deploy prod')"
first="$(printf '%s\n' "$out" | sed -n 's/^> Policy `\([^`]*\)`.*/\1/p' | head -1)"
[ "$first" = zz-deploy-direct ] && ok "direct match ranks first under the default ceiling" || bad "default ordering starts with $first"
n="$(bytes_of "$out")"
[ "$n" -le 4000 ] && ok "default reminder within 4000 bytes ($n)" || bad "default reminder is $n bytes"

echo "[b] summary-only HARD rules are parked for their trigger and come back in full later"
seen_file="$RA/workspace/orchestrator/policy-trigger-state/sa.seen.tsv"
# `when: always` rows score 0: delivered as one line they go to the session
# ledger (a score-0 seen entry could also mean "parked unseen", and the
# footer must name only delivered rows).
grep -q '^aaa-generic-1$' "$RA/workspace/orchestrator/policy-trigger-state/sa.txt" 2>/dev/null \
  && ok "a summarised unconditional HARD rule is recorded as delivered" \
  || bad "summarised HARD rule aaa-generic-1 was not recorded: $(cat "$RA/workspace/orchestrator/policy-trigger-state/sa.txt" 2>/dev/null)"
grep -q '^zz-deploy-direct$' "$RA/workspace/orchestrator/policy-trigger-state/sa.txt" \
  && ok "full-text rule recorded in the session ledger" || bad "full-text rule not in the session ledger"
listed1="$listed_a"
out2="$(run "$RA" sa 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES=3000)"
# Delivered rows are not listed again (ledger or seen set); rows the ceiling
# cut on the first event are listed now. The footer names the delivered
# command-specific HARD rules.
repeat=0
for s in $(printf '%s\n' "$out2" | sed -n 's/^> Policy `\([^`]*\)`.*/\1/p'); do printf '%s\n' "$listed1" | grep -x "$s" >/dev/null && repeat=$((repeat + 1)); done
[ "$repeat" = 0 ] && ok "same trigger repeats no delivered row" || bad "same trigger re-listed $repeat rows: $out2"
case "$out2" in
  *'> Already shown this session, still binding: '*'zz-deploy-direct'*) ok "the footer names the rule shown in full" ;;
  *) bad "footer missing or wrong: $out2" ;;
esac
case "$out2" in *'still binding: '*'yy-release-rule'*) ok "the footer names the HARD rule delivered as one line" ;; *) bad "footer lacks yy-release-rule: $out2" ;; esac
# A different trigger (release, not deploy): yy-release-rule matched only
# the common word deploy before (score 0), so its summary line consumed it;
# it is named in the footer, not re-shown.
out3="$(run "$RA" sa 'hq release now' HQ_POLICY_OUTPUT_CEILING_BYTES=3000)"
case "$out3" in
  *'> Policy `yy-release-rule`'*) bad "a delivered rule was re-listed on a new trigger: $out3" ;;
  *'still binding: '*'yy-release-rule'*) ok "a delivered rule is named in the footer on a new trigger" ;;
  *) bad "yy-release-rule missing from the footer: $out3" ;;
esac
# The rest drains: no slug is listed as its own line twice, every rule is
# listed once, and the output then shrinks to the footer.
delivered="$listed1"$'\n'"$(printf '%s\n' "$out2" | sed -n 's/^> Policy `\([^`]*\)`.*/\1/p')"
footer_only=""
for i in 1 2 3 4 5 6 7 8; do
  outn="$(run "$RA" sa 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES=3000)"
  ln="$(printf '%s\n' "$outn" | sed -n 's/^> Policy `\([^`]*\)`.*/\1/p')"
  if [ -z "$ln" ]; then footer_only=$i; break; fi
  for s in $ln; do printf '%s\n' "$delivered" | grep -x "$s" >/dev/null && bad "$s listed twice (drain event $i)"; done
  delivered="$delivered"$'\n'"$ln"
done
for i in 1 2 3 4 5 6; do
  printf '%s\n' "$delivered" | grep -x "aaa-generic-$i" >/dev/null || bad "aaa-generic-$i never delivered"
done
[ -n "$footer_only" ] && ok "every HARD rule was delivered once; the output then shrank to footer-only (drain event $footer_only)" || bad "the output never became footer-only"

echo "[c] output never exceeds the ceiling"
for ceiling in 200 500 900 1500 2500 4000 8000; do
  RC="$(new_root "ceil-$ceiling")"
  seed "$RC"
  out="$(prompt "$RC" "c-$ceiling" 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES="$ceiling")"
  n="$(bytes_of "$out")"
  [ -z "$out" ] && n=0
  [ "$n" -le "$ceiling" ] && [ "$n" -gt 0 ] && ok "UserPromptSubmit at $ceiling: $n bytes" \
    || bad "UserPromptSubmit at $ceiling emitted $n bytes"
  raw="$(post "$RC" "p-$ceiling" 'hq deploy prod' 'ok' HQ_POLICY_OUTPUT_CEILING_BYTES="$ceiling")"
  n="$(bytes_of "$raw")"
  [ -z "$raw" ] && n=0
  [ "$n" -le "$ceiling" ] && [ "$n" -gt 0 ] && ok "PostToolUse JSON at $ceiling: $n bytes" \
    || bad "PostToolUse JSON at $ceiling emitted $n bytes"
  printf '%s' "$raw" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
    || bad "PostToolUse output at $ceiling is not a valid envelope: $raw"
done

echo "[d] kept body lines that start with \"Policy \`\" survive the trim"
# Review of #1443: body lines quoted as "> Policy `..." looked like summary
# lines, so the trim cut them and the delivery check marked other slugs named
# in the body as delivered.
body_policy() { # <root> <id> <when> <enforcement> <body>
  printf -- '---\nid: %s\nwhen: %s\non: [PreToolUse, PostToolUse, UserPromptSubmit]\nenforcement: %s\n---\n\n## Rule\n\n%s\n' \
    "$2" "$3" "$4" "$5" > "$1/core/policies/$2.md"
}
filler="$(printf 'filler text for the body %.0s' $(seq 1 20))"
sub_body="NEVER deploy without the sub-rules."
for i in $(seq 1 20); do sub_body="$sub_body
Policy \`sub-$i\` must also be followed by every deploy step here."; done
keep_hits=0
for ceiling in $(seq 1000 100 3000); do
  RD="$(new_root "trim-body-$ceiling")"
  body_policy "$RD" zz-deploy-direct 'deploy && prod' hard "$sub_body"
  for i in 1 2 3; do policy "$RD" "aaa-gen-$i" always hard "ALWAYS generic $i. $filler"; done
  for i in 1 2 3 4 5 6 7 8; do policy "$RD" "soft-$i" deploy soft "Soft deploy note $i."; done
  out="$(prompt "$RD" "d-$ceiling" 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES="$ceiling")"
  case "$out" in
    *'> Policy `zz-deploy-direct` (HARD — binding rule from `'*) ;;
    *) continue ;;  # all-summary output at this ceiling; nothing kept to check
  esac
  keep_hits=$((keep_hits + 1))
  kept="$(grep -c '`sub-[0-9]*` must also be followed' <<<"$out" || true)"
  [ "$kept" = 20 ] || bad "ceiling $ceiling: only $kept of 20 kept body lines present"
done
[ "$keep_hits" -gt 0 ] && ok "kept HARD body intact at all $keep_hits keep-mode ceilings" \
  || bad "no ceiling in 1000..3000 kept the direct HARD rule in full"

cut_hits=0
for ceiling in $(seq 800 100 2500); do
  RE="$(new_root "false-delivered-$ceiling")"
  body_policy "$RE" zz-deploy-direct 'deploy && prod' hard "NEVER deploy without the checklist.
Policy \`aaa-gen-3\` covers the generic case.
Policy \`soft-8\` covers the soft case."
  for i in 1 2 3; do policy "$RE" "aaa-gen-$i" always hard "ALWAYS generic $i. $filler"; done
  for i in 1 2 3 4 5 6 7 8; do policy "$RE" "soft-$i" deploy soft "Soft deploy note $i."; done
  out="$(prompt "$RE" "e-$ceiling" 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES="$ceiling")"
  state="$RE/workspace/orchestrator/policy-trigger-state"
  for slug in aaa-gen-3 soft-8; do
    case "$out" in
      *'> Policy `'"$slug"'` applies here:'*|*'> Policy `'"$slug"'` (HARD — binding rule from `'*) continue ;;
    esac
    cut_hits=$((cut_hits + 1))
    # A cut row is parked in the seen set for this trigger; it must never
    # reach the session ledger, which would mark it delivered.
    if grep -q "^$slug\$" "$state/e-$ceiling.txt" 2>/dev/null; then
      bad "ceiling $ceiling: $slug was cut but recorded as delivered"
    fi
  done
done
[ "$cut_hits" -gt 0 ] && ok "no cut policy recorded as delivered across $cut_hits cut cases" \
  || bad "fixture never cut aaa-gen-3 or soft-8"

echo "[f] a large malformed-trigger notice cannot crowd out reactive policies"
RF="$(new_root malformed-flood)"
policy "$RF" zz-reactive 'deploy && prod' hard 'NEVER deploy without approval. REACTIVE_BODY'
for i in $(seq 1 150); do
  policy "$RF" "malformed-long-policy-identifier-for-notice-overflow-regression-$i" 'deploy && (' hard "Fallback $i."
done
for event in prompt post; do
  if [ "$event" = prompt ]; then
    out="$(prompt "$RF" "f-$event" 'hq deploy prod')"
    reminder="$out"
  else
    out="$(post "$RF" "f-$event" 'hq deploy prod' ok)"
    reminder="$(printf '%s' "$out" | context)"
  fi
  [ "$(bytes_of "$out")" -le 4000 ] && ok "$event malformed flood stays within ceiling" || bad "$event malformed flood exceeds ceiling"
  case "$reminder" in
    *'REACTIVE_BODY'*) ok "$event retains reactive policy body despite malformed flood" ;;
    *) bad "$event malformed notice crowded out reactive policy: $reminder" ;;
  esac
  case "$reminder" in
    *'150 policies'*'lint-policy-triggers.sh'*) ok "$event bounded malformed notice preserves count and repair command" ;;
    *) bad "$event missing bounded malformed diagnostic" ;;
  esac
  markers="$(grep -c '^__malformed-trigger-reported:' "$RF/workspace/orchestrator/policy-trigger-state/f-$event.txt" || true)"
  [ "$markers" = 150 ] && ok "$event records all 150 reported malformed diagnostics" || bad "$event recorded $markers diagnostic markers, expected 150"
  again="$(prompt "$RF" "f-$event" 'hq deploy prod')"
  case "$again" in
    *'Malformed `when:` trigger'*) bad "$event repeats the malformed diagnostic" ;;
    *) ok "$event malformed diagnostic recorded after delivery" ;;
  esac
done

if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures"
  exit 1
fi
echo "PASS"
