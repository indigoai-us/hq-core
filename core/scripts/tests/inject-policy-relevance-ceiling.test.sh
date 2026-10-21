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
  *'HARD policy `zz-deploy-direct` keeps its full text as the top-ranked match'*'Read each in full at its own file'*) ok "notice names the kept rule and keeps the read-the-file pointer" ;;
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

echo "[b] summary-only HARD rules are not repeated inside the seen window"
seen_file="$RA/workspace/orchestrator/policy-trigger-state/sa.seen.tsv"
[ -s "$seen_file" ] && ok "seen set written" || bad "seen set missing after a summarised HARD rule"
grep -q '^zz-deploy-direct$' "$RA/workspace/orchestrator/policy-trigger-state/sa.txt" \
  && ok "full-text rule recorded in the session ledger" || bad "full-text rule not in the session ledger"
if grep -q '^aaa-generic-1$' "$RA/workspace/orchestrator/policy-trigger-state/sa.txt" 2>/dev/null; then
  bad "summarised HARD rule was consumed by the session ledger"
else
  ok "summarised HARD rule left out of the session ledger"
fi
out2="$(run "$RA" sa 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES=3000)"
# Every policy shown by the first event (in full or as a summary) stays out;
# policies the first event cut for space are still eligible.
case "$out2" in
  *'`aaa-generic-1`'*|*'`aaa-generic-2`'*|*'`yy-release-rule`'*|*'`zz-deploy-direct`'*|*'`soft-'*)
    bad "same trigger repeated a shown policy inside the window: $out2" ;;
  *) ok "same trigger inside the window repeats no shown policy" ;;
esac
case "$out2" in
  *'`aaa-generic-3`'*) ok "a policy cut for space earlier is shown on the next event" ;;
  *) bad "policy cut for space was not shown on the next event: $out2" ;;
esac
out3="$(run "$RA" sa 'hq release now' HQ_POLICY_OUTPUT_CEILING_BYTES=3000)"
case "$out3" in
  *'`yy-release-rule`'*) ok "a new trigger brings the rule back" ;;
  *) bad "new trigger did not re-show yy-release-rule: $out3" ;;
esac
case "$out3" in
  *'`aaa-generic-'*) bad "generic rules repeated for an unchanged trigger key: $out3" ;;
  *) ok "rules with an unchanged trigger key stay suppressed" ;;
esac
# Age every seen entry past the default 1800-second window.
old="$(( $(date +%s) - 4000 ))"
awk -F '\t' -v old="$old" 'BEGIN { OFS="\t" } { $2 = old; print }' "$seen_file" > "$seen_file.tmp"
mv "$seen_file.tmp" "$seen_file"
out4="$(run "$RA" sa 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES=3000)"
case "$out4" in
  *'`aaa-generic-1`'*) ok "rule comes back after the TTL" ;;
  *) bad "rule not re-shown after the TTL expired: $out4" ;;
esac
# A short configured TTL expires on its own.
RB="$(new_root short-ttl)"
seed "$RB"
run "$RB" sb 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES=3000 >/dev/null
out5="$(run "$RB" sb 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES=3000 HQ_POLICY_SEEN_TTL_SECONDS=0)"
case "$out5" in
  *'`aaa-generic-1`'*) ok "HQ_POLICY_SEEN_TTL_SECONDS=0 disables suppression" ;;
  *) bad "zero TTL still suppressed the rule: $out5" ;;
esac
# A seen row stamped in the future (clock stepped back) counts as expired.
RF="$(new_root future-ttl)"
seed "$RF"
run "$RF" sf 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES=3000 >/dev/null
future_file="$RF/workspace/orchestrator/policy-trigger-state/sf.seen.tsv"
future="$(( $(date +%s) + 100000 ))"
awk -F '\t' -v t="$future" 'BEGIN { OFS="\t" } { $2 = t; print }' "$future_file" > "$future_file.tmp"
mv "$future_file.tmp" "$future_file"
out6="$(run "$RF" sf 'hq deploy prod' HQ_POLICY_OUTPUT_CEILING_BYTES=3000)"
case "$out6" in
  *'`aaa-generic-1`'*) ok "a future-stamped seen row does not suppress" ;;
  *) bad "future-stamped seen row still suppressed the rule: $out6" ;;
esac

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

if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures"
  exit 1
fi
echo "PASS"
