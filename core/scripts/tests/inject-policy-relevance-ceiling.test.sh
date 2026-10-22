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
#   [b] a HARD rule shown only as a summary is not repeated for the same
#       trigger inside the seen window; it comes back on a new trigger or once
#       the window expires.
#   [c] output never exceeds the configured ceiling, for plain stdout and for
#       the PostToolUse JSON envelope.
set -euo pipefail

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
    | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" "$@" bash "$HOOK" 2>/dev/null
}
post() { # <root> <sid> <command> <tool-output> [env...]
  local root="$1" sid="$2" command="$3" response="$4"
  shift 4
  jq -cn --arg sid "$sid" --arg command "$command" --arg response "$response" \
    '{session_id:$sid,hook_event_name:"PostToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:$command},tool_response:{stdout:$response,stderr:""}}' \
    | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" "$@" bash "$HOOK" 2>/dev/null
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

echo "[a] the most relevant HARD rule keeps its full text"
RA="$(new_root keep-top)"
seed "$RA"
out="$(run "$RA" sa 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES=3000)"
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
  *'HARD policy `zz-deploy-direct` keeps its full text as the top-ranked match'*'stays eligible and is shown in full on its next matching event. Read it at its file now'*) ok "notice names the kept rule, says the others stay eligible, and keeps the read-the-file pointer" ;;
  *) bad "ceiling notice missing the kept rule or the pointer: $out" ;;
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
[ "$n" -le 8000 ] && ok "default reminder within 8000 bytes ($n)" || bad "default reminder is $n bytes"

echo "[b] summary-only HARD rules are not parked; they come back in full (PR #1548 review)"
seen_file="$RA/workspace/orchestrator/policy-trigger-state/sa.seen.tsv"
grep -q 'aaa-generic-' "$seen_file" 2>/dev/null \
  && bad "a summarised HARD rule was parked in the seen set: $(cat "$seen_file")" \
  || ok "summarised HARD rules are not parked in the seen set"
grep -q '^zz-deploy-direct$' "$RA/workspace/orchestrator/policy-trigger-state/sa.txt" \
  && ok "full-text rule recorded in the session ledger" || bad "full-text rule not in the session ledger"
if grep -q '^aaa-generic-1$' "$RA/workspace/orchestrator/policy-trigger-state/sa.txt" 2>/dev/null; then
  bad "summarised HARD rule was consumed by the session ledger"
else
  ok "summarised HARD rule left out of the session ledger"
fi
out2="$(run "$RA" sa 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES=3000)"
# The full-text rule and shown soft rows stay out; a HARD rule shown only as
# its summary is still eligible and comes back.
case "$out2" in
  *'> Policy `zz-deploy-direct`'*|*'> Policy `soft-'*)
    bad "same trigger repeated a policy delivered in full: $out2" ;;
  *) ok "same trigger repeats no policy delivered in full" ;;
esac
case "$out2" in
  *'`aaa-generic-1`'*) ok "a HARD rule shown only as a summary is shown again" ;;
  *) bad "summarised HARD rule aaa-generic-1 did not come back: $out2" ;;
esac
case "$out2" in
  *'`aaa-generic-3`'*) ok "a policy cut for space earlier is shown on the next event" ;;
  *) bad "policy cut for space was not shown on the next event: $out2" ;;
esac
out3="$(run "$RA" sa 'hq release now' HQ_POLICY_OUTPUT_CEILING_BYTES=3000)"
case "$out3" in
  *'> Policy `yy-release-rule`'*) bad "a rule delivered in full was repeated on a new trigger: $out3" ;;
  *) ok "a rule delivered in full is not repeated on a new trigger" ;;
esac
case "$out3" in
  *'> Policy `aaa-generic-1` (HARD — binding rule from `'*GENERIC_BODY_1*) ok "a HARD rule shortened earlier is now shown in full" ;;
  *) bad "aaa-generic-1 still not in full: $out3" ;;
esac
# Shortened HARD rules drain: each later event shows the next one in full,
# and none is shown in full twice. Nothing is parked in the seen set.
full_seen=" aaa-generic-1 "
for i in 1 2 3 4 5 6 7 8; do
  outn="$(run "$RA" sa 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES=3000)"
  for slug in $(printf '%s\n' "$outn" | sed -n 's/^> Policy `\([^`]*\)` (HARD — binding rule from .*/\1/p'); do
    case "$full_seen" in *" $slug "*) bad "$slug shown in full twice" ;; esac
    full_seen="$full_seen$slug "
  done
done
for i in 1 2 3 4 5 6; do
  case "$full_seen" in *" aaa-generic-$i "*) ;; *) bad "aaa-generic-$i never reached full text: $full_seen" ;; esac
done
ok "every shortened HARD rule reached full text once ($full_seen)"
grep -q 'aaa-generic-' "$seen_file" 2>/dev/null && bad "a HARD rule was parked: $(cat "$seen_file")" || ok "no HARD rule parked across the drain"

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
    if grep -q "^$slug\$" "$state/e-$ceiling.txt" 2>/dev/null \
      || grep -q "^$slug	" "$state/e-$ceiling.seen.tsv" 2>/dev/null; then
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
  [ "$(bytes_of "$out")" -le 8000 ] && ok "$event malformed flood stays within ceiling" || bad "$event malformed flood exceeds ceiling"
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
