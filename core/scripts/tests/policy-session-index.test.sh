#!/usr/bin/env bash
# policy-session-index.test.sh
# Flag off leaves the reminder path alone. Flag on pins a per-session index:
# full emit at SessionStart, delta for a new rule, must-fire text on its
# trigger, a stored re-emit every N turns, a rebuild on compaction, a cap,
# a company-scoped file, and SessionEnd cleanup. Review fixes: the
# enforcement-gate context with the flag on, a shared must-fire budget under
# the output ceiling, one every-N re-emit per prompt, SessionEnd through the
# registry plus an age sweep, stale-lock takeover, and a bounded jq count.
# Explicitly wired into .github/workflows/pr-checks.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
INDEX="$ROOT/core/scripts/policy-session-index.sh"
TRIAL="$ROOT/core/scripts/policy-session-index-trial.py"
PASS=0
FAIL=0
ok() { echo "  ok $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null || { echo "jq required"; exit 2; }
grep -q 'policy-session-index.test.sh' "$ROOT/.github/workflows/pr-checks.yml" \
  || { echo "test is not wired into pr-checks.yml"; exit 2; }
[ -f "$HOOK" ] && [ -f "$INDEX" ] && [ -f "$TRIAL" ] || { echo "missing hook, index, or trial script"; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/hq/core/policies" "$tmp/hq/core/scripts" "$tmp/hq/.claude/hooks" \
  "$tmp/hq/workspace/orchestrator/policy-trigger-state"
cp "$HOOK" "$tmp/hq/.claude/hooks/inject-policy-on-trigger.sh"
cp "$INDEX" "$tmp/hq/core/scripts/policy-session-index.sh"
printf '#!/bin/bash\nprintf "always check\\n"\n' > "$tmp/hq/core/scripts/derive-trigger-facts.sh"
printf '#!/bin/bash\nexit 0\n' > "$tmp/hq/core/scripts/eval-trigger.sh"
chmod +x "$tmp/hq/core/scripts/"*.sh

write_policy() {
  local slug="$1" enf="$2" rule="$3" when="${4:-always}" on="${5:-[SessionStart, UserPromptSubmit, PostToolUse]}"
  cat > "$tmp/hq/core/policies/${slug}.md" <<EOF
---
id: ${slug}
when: ${when}
on: ${on}
enforcement: ${enf}
---
## Rule
${rule}
EOF
}

write_policy hot-style soft "Keep the hot style note short."
write_policy cold-style soft "Cold style note that should collapse."
write_policy secret-guard hard "Never print a credential. BINDING-SECRET-SENTINEL applies before any other step."

run_event() {
  local sid="$1" ev="$2" source="${3:-}"
  local input errfile
  errfile="$tmp/err.txt"
  input="$(jq -cn --arg sid "$sid" --arg cwd "$tmp/hq" --arg ev "$ev" --arg source "$source" \
    '{session_id:$sid,hook_event_name:$ev,cwd:$cwd,source:(if $source == "" then null else $source end),tool_name:"Bash",prompt:"check the rules",tool_input:{command:"true"}}')"
  HQ_POLICY_FACT_HELPER_DISABLE=1 HQ_ROOT="$tmp/hq" CLAUDE_PROJECT_DIR="$tmp/hq" \
    bash "$tmp/hq/.claude/hooks/inject-policy-on-trigger.sh" <<<"$input" 2>"$errfile" || true
}

index_file() {
  printf '%s\n' "$tmp/hq/workspace/orchestrator/policy-session-index/${1}--${2}.json"
}

# Flag off: no index file, no index block.
off_sid="off$$"
off_out="$(HQ_POLICY_SESSION_INDEX=0 run_event "$off_sid" SessionStart)"
[[ "$off_out" != *"<policy-index>"* ]] && ok "flag off: no index block" || bad "flag off: index block leaked: $off_out"
[ ! -e "$(index_file "$off_sid" unscoped)" ] && ok "flag off: no index file" || bad "flag off: index file created"
[[ "$off_out" == *"hot-style"* ]] && ok "flag off: reminder still names the rule" || bad "flag off: reminder missing the rule: $off_out"
off_stats="$tmp/hq/workspace/orchestrator/policy-emit-stats/${off_sid}.txt"
if [ -f "$off_stats" ]; then
  off_fields="$(awk -F '\t' 'NF>0 { print NF; exit }' "$off_stats")"
  [ "$off_fields" = "4" ] && ok "flag off: stats stay four fields" || bad "flag off: stats fields=$off_fields"
else
  bad "flag off: no stats line"
fi

# Flag on. Personal file is the other switch; env is the one used here.
export HQ_POLICY_SESSION_INDEX=1
export HQ_POLICY_SESSION_INDEX_EVERY=2
export HQ_POLICY_SESSION_INDEX_CAP=40
export HQ_POLICY_SESSION_INDEX_RECENT=25

on_sid="on$$"
on_out="$(run_event "$on_sid" SessionStart)"
[[ "$on_out" == *"<policy-index>"* ]] && ok "session start: index block" || bad "session start: no index block: $on_out $(cat "$tmp/err.txt")"
[[ "$on_out" == *"Pull full text before acting."* ]] && ok "session start: hard line tells the model to pull full text" || bad "session start: hard marker missing"
[[ "$on_out" == *"secret-guard"* && "$on_out" == *"hot-style"* && "$on_out" == *"cold-style"* ]] \
  && ok "session start: all three rules are pinned" || bad "session start: missing a rule"
on_file="$(index_file "$on_sid" unscoped)"
[ -f "$on_file" ] && ok "session start: index file exists" || bad "session start: index file missing"
on_stats="$tmp/hq/workspace/orchestrator/policy-emit-stats/${on_sid}.txt"
awk -F '\t' '$5 == "index" { found=1 } END { exit !found }' "$on_stats" \
  && ok "session start: stats type is index" || bad "session start: stats type missing ($(cat "$on_stats" 2>/dev/null))"
[[ "$on_out" == *"BINDING-SECRET-SENTINEL"* ]] \
  && ok "session start: must-fire binding text" || bad "session start: binding text missing"

# A rule that appears after session start is a delta. Already pinned rules
# stay quiet. The follow-up is a prompt: a tool event does not re-show an
# unconditional rule that also listens on SessionStart.
write_policy late-note soft "A late note added after the index was pinned."
delta="$(run_event "$on_sid" UserPromptSubmit)"
[[ "$delta" == *"Added to this session's rules: late-note"* ]] \
  && ok "delta: new rule is the only addition" || bad "delta: late note missing: $delta"
[[ "$delta" != *"Added to this session's rules: hot-style"* ]] \
  && ok "delta: pinned rules stay quiet" || bad "delta: pinned rule repeated"
[[ "$delta" != *"Added to this session's rules: secret-guard"* ]] \
  && ok "delta: must-fire rule is not added again" || bad "delta: must-fire rule was re-added"

# A conditional must-fire rule that matches a later prompt is named again as
# still binding (full text was shown once), without a second "Added" line.
write_policy recheck-secret hard "Recheck sentinel RECHECK-SECRET-SENTINEL stays binding." check "[SessionStart, UserPromptSubmit]"
re_sid="re$$"
re_first="$(run_event "$re_sid" SessionStart)"
[[ "$re_first" == *"RECHECK-SECRET-SENTINEL"* ]] \
  && ok "must-fire: first trigger includes binding text" || bad "must-fire: first trigger missing text: $re_first"
re_again="$(run_event "$re_sid" UserPromptSubmit)"
[[ "$re_again" == *"Still binding"*"recheck-secret"* ]] \
  && ok "must-fire: later trigger names the rule as still binding" || bad "must-fire: later trigger missing reference: $re_again"
[[ "$re_again" != *"Added to this session's rules: recheck-secret"* ]] \
  && ok "must-fire: later trigger is not a new index line" || bad "must-fire: later trigger re-added the rule: $re_again"

# A tool-only rule is delivered as PostToolUse additionalContext.
write_policy tool-note soft "Tool note visible on the tool event." always "[PostToolUse]"
tool_sid="tool$$"
tool_out="$(run_event "$tool_sid" PostToolUse)"
tool_ctx="$(printf '%s' "$tool_out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
[ "$(printf '%s' "$tool_out" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null || true)" = "PostToolUse" ] \
  && ok "post tool: stdout is additionalContext JSON" || bad "post tool: not JSON: $tool_out"
[[ "$tool_ctx" == *"tool-note"* ]] \
  && ok "post tool: new tool rule is inside the context" || bad "post tool: tool rule missing: $tool_ctx"

# Every N turns re-emits the stored index and does not collapse a cold rule
# that this event did not match.
keep_sid="keep$$"
run_event "$keep_sid" SessionStart >/dev/null
keep_file="$(index_file "$keep_sid" unscoped)"
jq '.turn = 1 | .entries |= map(if .slug == "cold-style" then .last_trigger_turn = 0 else . end)' \
  "$keep_file" > "$keep_file.tmp" && mv "$keep_file.tmp" "$keep_file"
rm -f "$tmp/hq/core/policies/cold-style.md"
keep_out="$(run_event "$keep_sid" UserPromptSubmit)"
[[ "$keep_out" == *"<policy-index>"* && "$keep_out" == *"cold-style"* ]] \
  && ok "periodic re-emit: stored cold rule stays" || bad "periodic re-emit: cold rule dropped: $keep_out"
jq -e '.entries | map(.slug) | index("cold-style") != null' "$keep_file" >/dev/null \
  && ok "periodic re-emit: cold rule still on disk" || bad "periodic re-emit: disk lost the cold rule"

# Compaction rebuilds: keep hard rules, re-score a recent soft rule, collapse a cold one, emit once.
write_policy cold-style soft "Cold style note that should collapse."
comp_sid="comp$$"
run_event "$comp_sid" SessionStart >/dev/null
comp_file="$(index_file "$comp_sid" unscoped)"
jq '.turn = 30
  | .entries |= map(
      if .slug == "cold-style" then .last_trigger_turn = 0
      elif .slug == "hot-style" then .last_trigger_turn = 30
      else . end)' \
  "$comp_file" > "$comp_file.tmp" && mv "$comp_file.tmp" "$comp_file"
rm -f "$tmp/hq/core/policies/cold-style.md" "$tmp/hq/core/policies/secret-guard.md"
comp_out="$(run_event "$comp_sid" SessionStart compact)"
index_blocks="$(printf '%s' "$comp_out" | grep -c '<policy-index>' || true)"
[ "$index_blocks" = "1" ] && ok "compaction: one index emit" || bad "compaction: index blocks=$index_blocks out=$comp_out"
[[ "$comp_out" != *"Added to this session's rules:"* ]] \
  && ok "compaction: not a delta" || bad "compaction: emitted a delta"
jq -e '.entries | map(.slug) | index("secret-guard") != null' "$comp_file" >/dev/null \
  && ok "compaction: hard rule kept" || bad "compaction: hard rule dropped"
jq -e '.entries | map(.slug) | index("hot-style") != null' "$comp_file" >/dev/null \
  && ok "compaction: recent soft rule kept" || bad "compaction: hot rule dropped"
jq -e '.entries | map(.slug) | index("cold-style") == null' "$comp_file" >/dev/null \
  && ok "compaction: cold soft rule collapsed" || bad "compaction: cold rule still pinned"
[[ "$comp_out" == *"older rules (topic "*"cold-style"* ]] \
  && ok "compaction: collapsed rules name a topic" || bad "compaction: no collapse line: $comp_out"

# Cap. One hard rule plus four soft rules, cap 3, so two soft rules collapse.
write_policy secret-guard hard "Never print a credential. BINDING-SECRET-SENTINEL applies before any other step."
write_policy cold-style soft "Cold style note that should collapse."
write_policy extra-one soft "Extra one."
write_policy extra-two soft "Extra two."
export HQ_POLICY_SESSION_INDEX_CAP=3
cap_sid="cap$$"
run_event "$cap_sid" SessionStart >/dev/null
cap_file="$(index_file "$cap_sid" unscoped)"
cap_n="$(jq '.entries | length' "$cap_file")"
[ "$cap_n" -le 3 ] && ok "cap: at most 3 entries ($cap_n)" || bad "cap: entries=$cap_n"
jq -e '.entries | map(.slug) | index("secret-guard") != null' "$cap_file" >/dev/null \
  && ok "cap: hard rule kept" || bad "cap: hard rule collapsed"
collapsed_n="$(jq '[.collapsed[].count] | add // 0' "$cap_file")"
[ "$collapsed_n" -ge 2 ] && ok "cap: collapsed the overflow ($collapsed_n)" || bad "cap: collapsed=$collapsed_n"
export HQ_POLICY_SESSION_INDEX_CAP=40

# Company scope: a marker planted for one company is not visible to another.
co_sid="co$$"
HQ_POLICY_COMPANY=alpha run_event "$co_sid" SessionStart >/dev/null
alpha_file="$(index_file "$co_sid" alpha)"
[ -f "$alpha_file" ] && ok "company: alpha file" || bad "company: alpha file missing"
jq '.entries += [{slug:"alpha-only",weight:"soft",topic:"alpha",line:"alpha only",score:1,last_trigger_turn:0,added_turn:0,mustfire:false}]' \
  "$alpha_file" > "$alpha_file.tmp" && mv "$alpha_file.tmp" "$alpha_file"
HQ_POLICY_COMPANY=beta run_event "$co_sid" SessionStart >/dev/null
beta_file="$(index_file "$co_sid" beta)"
[ -f "$beta_file" ] && ok "company: beta file" || bad "company: beta file missing"
jq -e '.entries | map(.slug) | index("alpha-only") == null' "$beta_file" >/dev/null \
  && ok "company: beta does not see alpha's entry" || bad "company: beta mixed in alpha"
jq -e '.entries | map(.slug) | index("alpha-only") != null' "$alpha_file" >/dev/null \
  && ok "company: alpha keeps its own entry" || bad "company: alpha entry lost"

# SessionEnd removes the session's index files.
end_sid="end$$"
run_event "$end_sid" SessionStart >/dev/null
end_file="$(index_file "$end_sid" unscoped)"
[ -f "$end_file" ] || bad "cleanup: index was not created"
run_event "$end_sid" SessionEnd >/dev/null
[ ! -e "$end_file" ] && ok "cleanup: SessionEnd removes the index" || bad "cleanup: index remains"

# The Grok adapter ends a session by sending a SessionEnd payload with
# HQ_POLICY_DROP_HELD=1. The SessionEnd cleanup must not stop that call before
# the injector drops the reminders it was holding. Flag on and flag off.
for held_flag in 1 0; do
  held_sid="heldend${held_flag}x$$"
  held_dir="$tmp/hq/workspace/orchestrator/policy-trigger-state/${held_sid}.held"
  held_index="$(index_file "$held_sid" unscoped)"
  mkdir -p "$held_dir" "$(dirname "$held_index")"
  printf 'held reminder text\n' > "$held_dir/out"
  printf '{}\n' > "$held_index"
  held_out="$(jq -cn --arg sid "$held_sid" --arg cwd "$tmp/hq" '{session_id:$sid,hook_event_name:"SessionEnd",cwd:$cwd}' \
    | HQ_POLICY_SESSION_INDEX="$held_flag" HQ_HARNESS=grok HQ_POLICY_DROP_HELD=1 \
      HQ_POLICY_FACT_HELPER_DISABLE=1 HQ_ROOT="$tmp/hq" CLAUDE_PROJECT_DIR="$tmp/hq" \
      bash "$tmp/hq/.claude/hooks/inject-policy-on-trigger.sh" 2>/dev/null || true)"
  [ ! -e "$held_dir" ] && ok "grok SessionEnd (flag $held_flag): held reminders dropped" \
    || bad "grok SessionEnd (flag $held_flag): held reminders remain"
  [ ! -e "$held_index" ] && ok "grok SessionEnd (flag $held_flag): session index removed" \
    || bad "grok SessionEnd (flag $held_flag): index remains"
  [ -z "$held_out" ] && ok "grok SessionEnd (flag $held_flag): no stdout" \
    || bad "grok SessionEnd (flag $held_flag): printed output"
done

# --- Review fixes -----------------------------------------------------------

bytes_of() {
  local LC_ALL=C s="$1"
  printf '%s' "$(( ${#s} + 1 ))"
}

# Fix 1: the enforcement-gate context reaches the model with the flag on.
gate_sid="gate$$"
cat > "$tmp/hq/.claude/hooks/hook-gate.sh" <<'EOF'
hq_hook_profile_allows() { return 0; }
EOF
cat > "$tmp/hq/.claude/hooks/policy-enforcement-gate.sh" <<'EOF'
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"GATE-CONTEXT-SENTINEL"}}\n'
EOF
run_event "$gate_sid" SessionStart >/dev/null
gate_out="$(run_event "$gate_sid" UserPromptSubmit)"
[[ "$gate_out" == *"<policy-enforcement>"*"GATE-CONTEXT-SENTINEL"*"</policy-enforcement>"* ]] \
  && ok "enforcement gate: context printed with the flag on" \
  || bad "enforcement gate: context dropped: $gate_out"
gate_quiet="$(run_event "$gate_sid" UserPromptSubmit)"
[[ "$gate_quiet" == *"GATE-CONTEXT-SENTINEL"* ]] \
  && ok "enforcement gate: context printed on a quiet turn" \
  || bad "enforcement gate: quiet turn dropped it: $gate_quiet"
rm -f "$tmp/hq/.claude/hooks/hook-gate.sh" "$tmp/hq/.claude/hooks/policy-enforcement-gate.sh"

# Fix 3: every-N re-emits once per qualifying prompt, not on each tool event
# in that turn.
export HQ_POLICY_SESSION_INDEX_EVERY=2
evn_sid="evn$$"
run_event "$evn_sid" SessionStart >/dev/null
run_event "$evn_sid" UserPromptSubmit >/dev/null
evn_prompt="$(run_event "$evn_sid" UserPromptSubmit)"
[[ "$evn_prompt" == *"Rules pinned for this session"* ]] \
  && ok "every-N: prompt N re-emits the index" || bad "every-N: no re-emit at prompt N: $evn_prompt"
evn_tools=""
for _ in 1 2 3; do
  evn_tools+="$(run_event "$evn_sid" PostToolUse)"$'\n'
done
evn_count="$(printf '%s' "$evn_tools" | { grep -o 'Rules pinned for this session' || true; } | wc -l | tr -d ' ')"
[ "$evn_count" = "0" ] && ok "every-N: tool events in turn N do not re-emit" \
  || bad "every-N: $evn_count tool events re-emitted the index"
jq -e '.last_index_turn == 2' "$(index_file "$evn_sid" unscoped)" >/dev/null \
  && ok "every-N: last emit turn stored" || bad "every-N: last_index_turn missing"

# Fix 5: a lock left by a killed hook is taken over.
lock_sid="lock$$"
run_event "$lock_sid" SessionStart >/dev/null
lock_file="$(index_file "$lock_sid" unscoped)"
sh -c 'exit 0' &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
mkdir "$lock_file.lock"
printf '%s\n' "$dead_pid" > "$lock_file.lock/pid"
printf '%s\n' "$(( $(date +%s) - 3600 ))" > "$lock_file.lock/time"
run_event "$lock_sid" UserPromptSubmit >/dev/null
jq -e '.turn == 1' "$lock_file" >/dev/null \
  && ok "stale lock: write happened after reclaim" || bad "stale lock: index not written ($(jq -c .turn "$lock_file"))"
[ ! -e "$lock_file.lock" ] && ok "stale lock: lock released" || bad "stale lock: lock remains"

# Metadata decides must-fire: frontmatter mustfire and tags, not only words
# in the slug.
cat > "$tmp/hq/core/policies/approval-gate.md" <<'EOF'
---
id: approval-gate
when: always
on: [SessionStart, UserPromptSubmit, PostToolUse]
enforcement: hard
mustfire: true
---
## Rule
Ask first. APPROVAL-GATE-SENTINEL.
EOF
cat > "$tmp/hq/core/policies/vault-rule.md" <<'EOF'
---
id: vault-rule
when: always
on: [SessionStart, UserPromptSubmit, PostToolUse]
enforcement: hard
tags: [security, vault]
---
## Rule
Vault rule. VAULT-TAG-SENTINEL.
EOF
cat > "$tmp/hq/core/policies/secret-optout.md" <<'EOF'
---
id: secret-optout
when: always
on: [SessionStart, UserPromptSubmit, PostToolUse]
enforcement: hard
mustfire: false
---
## Rule
Opted out. SECRET-OPTOUT-SENTINEL.
EOF
meta_out="$(run_event "meta$$" SessionStart)"
[[ "$meta_out" == *"APPROVAL-GATE-SENTINEL"* ]] && ok "must-fire: frontmatter mustfire: true" || bad "must-fire: frontmatter flag ignored"
[[ "$meta_out" == *"VAULT-TAG-SENTINEL"* ]] && ok "must-fire: security tag" || bad "must-fire: tag ignored"
meta_reminder="${meta_out#*<policy-reminder>}"
meta_reminder="${meta_reminder%%</policy-reminder>*}"
[[ "$meta_reminder" != *"SECRET-OPTOUT-SENTINEL"* && "$meta_out" == *"secret-optout"* ]] \
  && ok "must-fire: mustfire: false opts a secret slug out" || bad "must-fire: opt-out ignored: $meta_out"
[[ "$meta_out" == *"[soft · vault]"* || "$meta_out" == *"[HARD · security]"* ]] \
  && ok "topic: taken from policy tags" || bad "topic: tags not used: $meta_out"
rm -f "$tmp/hq/core/policies/approval-gate.md" "$tmp/hq/core/policies/vault-rule.md" "$tmp/hq/core/policies/secret-optout.md"

# A missing session id keeps today's reminder (no shared default file).
nosid_input="$(jq -cn --arg cwd "$tmp/hq" '{hook_event_name:"SessionStart",cwd:$cwd,tool_name:"Bash",prompt:"x",tool_input:{command:"true"}}')"
nosid_out="$(HQ_POLICY_FACT_HELPER_DISABLE=1 HQ_ROOT="$tmp/hq" CLAUDE_PROJECT_DIR="$tmp/hq" \
  bash "$tmp/hq/.claude/hooks/inject-policy-on-trigger.sh" <<<"$nosid_input" 2>/dev/null || true)"
[[ "$nosid_out" != *"<policy-index>"* && "$nosid_out" == *"hot-style"* ]] \
  && ok "no session id: reminder path" || bad "no session id: $nosid_out"
[ ! -e "$(index_file default unscoped)" ] && ok "no session id: no shared default file" || bad "no session id: default file written"

# Fix 2: must-fire text shares the base budget and the output ceiling.
big_text=""
for _ in $(seq 1 18); do big_text+="Binding detail line that keeps this credential rule long enough to matter. "$'\n'; done
for n in 1 2 3 4 5 6; do
  cat > "$tmp/hq/core/policies/secret-big-$n.md" <<EOF
---
id: secret-big-$n
when: always
on: [SessionStart, UserPromptSubmit, PostToolUse]
enforcement: hard
---
## Rule
Never print secret number $n. BIG-SENTINEL-$n.
$big_text
EOF
done
big_out="$(run_event "big$$" SessionStart)"
big_bytes="$(bytes_of "$big_out")"
[ "$big_bytes" -le 4000 ] && ok "ceiling: SessionStart with six long must-fire rules ($big_bytes bytes)" \
  || bad "ceiling: SessionStart $big_bytes bytes > 4000"
all_named=1
for n in 1 2 3 4 5 6; do [[ "$big_out" == *"secret-big-$n"* ]] || all_named=0; done
[ "$all_named" = 1 ] && ok "ceiling: every must-fire rule is still named" || bad "ceiling: a must-fire rule vanished"
[[ "$big_out" == *"full text withheld for"* ]] && ok "ceiling: withheld bodies are named" || bad "ceiling: no withheld notice"
[[ "$big_out" == *"BIG-SENTINEL-1"* ]] && ok "ceiling: first body still delivered" || bad "ceiling: no body delivered"
for n in 7 8 9; do
  sed "s/secret-big-1/secret-big-$n/; s/number 1/number $n/; s/BIG-SENTINEL-1/BIG-SENTINEL-$n/" \
    "$tmp/hq/core/policies/secret-big-1.md" > "$tmp/hq/core/policies/secret-big-$n.md"
done
big_delta="$(run_event "big$$" PostToolUse)"
big_delta_bytes="$(bytes_of "$big_delta")"
[ "$big_delta_bytes" -le 4000 ] && ok "ceiling: PostToolUse delta stays under ($big_delta_bytes bytes)" \
  || bad "ceiling: PostToolUse delta $big_delta_bytes bytes > 4000"
printf '%s' "$big_delta" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
  && ok "ceiling: delta is valid JSON" || bad "ceiling: delta JSON broken"

# HARD index lines are never dropped by the trim.
for n in $(seq 1 30); do
  write_policy "soft-filler-$n" soft "Soft filler rule number $n with enough words to take some room in the index line."
done
fill_out="$(run_event "fill$$" SessionStart)"
fill_bytes="$(bytes_of "$fill_out")"
[ "$fill_bytes" -le 4000 ] && ok "trim: index fits ($fill_bytes bytes)" || bad "trim: $fill_bytes bytes > 4000"
fill_hard=1
for slug in secret-guard secret-big-1 secret-big-9; do [[ "$fill_out" == *"\`$slug\`"* ]] || fill_hard=0; done
[ "$fill_hard" = 1 ] && ok "trim: HARD lines kept" || bad "trim: a HARD line was dropped"
[[ "$fill_out" == *"rules withheld by the 4000-byte output budget"* ]] \
  && ok "trim: trimmed lines are counted" || bad "trim: silent trim"
rm -f "$tmp/hq/core/policies/secret-big-"*.md "$tmp/hq/core/policies/soft-filler-"*.md

# Fix 6: process cost. Flag on adds a fixed two jq runs at most (the merge
# and, for PostToolUse, the JSON wrap) whatever the number of matched rules;
# the old per-row loop spawned several per rule.
shim="$tmp/shim"
mkdir -p "$shim"
real_jq="$(command -v jq)"
printf '#!/bin/sh\necho x >> "%s"\nexec "%s" "$@"\n' "$tmp/jq-count" "$real_jq" > "$shim/jq"
chmod +x "$shim/jq"
count_jq() {
  : > "$tmp/jq-count"
  PATH="$shim:$PATH" "$@" >/dev/null
  wc -l < "$tmp/jq-count" | tr -d ' '
}
off_n="$(HQ_POLICY_SESSION_INDEX=0 count_jq run_event "jqoff$$" SessionStart)"
on_n="$(count_jq run_event "jqon$$" SessionStart)"
[ "$on_n" -le $((off_n + 2)) ] && ok "cost: SessionStart jq runs on=$on_n off=$off_n" \
  || bad "cost: SessionStart jq runs on=$on_n > off=$off_n + 2"
off_t="$(HQ_POLICY_SESSION_INDEX=0 count_jq run_event "jqoff$$" PostToolUse)"
on_t="$(count_jq run_event "jqon$$" PostToolUse)"
[ "$on_t" -le $((off_t + 2)) ] && ok "cost: PostToolUse jq runs on=$on_t off=$off_t" \
  || bad "cost: PostToolUse jq runs on=$on_t > off=$off_t + 2"

# Fix 4: SessionEnd is registered and reaches the injector through the
# master hook; an age sweep removes files a crashed session left.
REG="$ROOT/.claude/hooks/hook-registry.json"
jq -e '[.hooks.SessionEnd[]?.hooks[]? | select(.id == "inject-policy-on-trigger")] | length == 1' "$REG" >/dev/null \
  && ok "registry: injector registered for SessionEnd" || bad "registry: injector not on SessionEnd"
reg="$tmp/reg"
mkdir -p "$reg/.claude" "$reg/core" "$reg/workspace/orchestrator/policy-session-index"
cp -R "$ROOT/.claude/hooks" "$reg/.claude/hooks"
cp -R "$ROOT/core/scripts" "$reg/core/scripts"
jq '{hooks: {SessionEnd: [.hooks.SessionEnd[] | .hooks |= map(select(.id == "inject-policy-on-trigger")) | select(.hooks | length > 0)]}}' \
  "$REG" > "$reg/.claude/hooks/hook-registry.json"
reg_dir="$reg/workspace/orchestrator/policy-session-index"
printf '{}\n' > "$reg_dir/regend--alpha.json"
printf '{}\n' > "$reg_dir/other--unscoped.json"
printf '{}\n' > "$reg_dir/crashed--unscoped.json"
touch -t 202001010000 "$reg_dir/crashed--unscoped.json"
jq -cn --arg cwd "$reg" '{session_id:"regend",hook_event_name:"SessionEnd",cwd:$cwd,reason:"exit"}' \
  | env -u HQ_POLICY_SESSION_INDEX HQ_ROOT="$reg" CLAUDE_PROJECT_DIR="$reg" \
    bash "$reg/.claude/hooks/master-hook.sh" SessionEnd >/dev/null 2>"$tmp/reg-err.txt" || true
[ ! -e "$reg_dir/regend--alpha.json" ] && ok "registry SessionEnd: session index removed" \
  || bad "registry SessionEnd: index remains ($(head -c 400 "$tmp/reg-err.txt"))"
[ -e "$reg_dir/other--unscoped.json" ] && ok "registry SessionEnd: other session kept" || bad "registry SessionEnd: removed another session"
[ ! -e "$reg_dir/crashed--unscoped.json" ] && ok "sweep: old index from a crashed session removed" || bad "sweep: old file remains"

# --- Re-review fixes --------------------------------------------------------

# A: many HARD rules with no must-fire rule end the fit loop. The hook must
# finish well inside a timeout and print a bounded index. Must-fire rules
# are parked so none is in the output; a 1500-byte ceiling forces the fold.
mkdir -p "$tmp/parked"
mv "$tmp/hq/core/policies/secret-guard.md" "$tmp/hq/core/policies/recheck-secret.md" "$tmp/parked/"
for n in $(seq 1 80); do
  write_policy "plain-hard-$n" hard "Plain hard rule number $n that needs a decent length line in the pinned index."
done
# Portable timeout: run in the background, kill after 20 s.
loop_start="$(date +%s)"
( HQ_POLICY_OUTPUT_CEILING_BYTES=1500 run_event "loop$$" SessionStart > "$tmp/loop-out.txt" ) &
loop_pid=$!
loop_waited=0
while kill -0 "$loop_pid" 2>/dev/null && [ "$loop_waited" -lt 20 ]; do
  sleep 1
  loop_waited=$((loop_waited + 1))
done
if kill -0 "$loop_pid" 2>/dev/null; then
  pkill -P "$loop_pid" 2>/dev/null || true
  kill "$loop_pid" 2>/dev/null || true
fi
wait "$loop_pid" 2>/dev/null || true
loop_out="$(cat "$tmp/loop-out.txt" 2>/dev/null || true)"
loop_secs=$(( $(date +%s) - loop_start ))
[ "$loop_secs" -lt 20 ] && ok "fit loop: ends with 80 HARD rules and no must-fire (${loop_secs}s)" \
  || bad "fit loop: took ${loop_secs}s"
[[ "$loop_out" == *"<policy-index>"* ]] && ok "fit loop: index printed" || bad "fit loop: nothing printed"
loop_bytes="$(bytes_of "$loop_out")"
[ "$loop_bytes" -le 1500 ] && ok "fit loop: under the ceiling ($loop_bytes bytes)" || bad "fit loop: $loop_bytes bytes"
[[ "$loop_out" == *"HARD rules pinned:"* ]] && ok "fit loop: HARD lines folded, not dropped" || bad "fit loop: no fold line: $loop_out"
mv "$tmp/parked/secret-guard.md" "$tmp/parked/recheck-secret.md" "$tmp/hq/core/policies/"

# B: the ceiling holds on every event, with must-fire rules and the gate
# block present, and a delta of many new HARD rules.
cat > "$tmp/hq/.claude/hooks/hook-gate.sh" <<'EOF'
hq_hook_profile_allows() { return 0; }
EOF
cat > "$tmp/hq/.claude/hooks/policy-enforcement-gate.sh" <<'EOF'
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"GATE-CEILING-SENTINEL"}}\n'
EOF
ceil_sid="ceil$$"
ceil_ss="$(run_event "$ceil_sid" SessionStart)"
for n in $(seq 81 150); do
  write_policy "plain-hard-$n" hard "Plain hard rule number $n that arrives later as a delta in the session."
done
ceil_ups="$(run_event "$ceil_sid" UserPromptSubmit)"
for n in $(seq 151 220); do
  write_policy "plain-hard-$n" hard "Plain hard rule number $n that arrives later as a tool delta." always "[PostToolUse]"
done
ceil_ptu="$(run_event "$ceil_sid" PostToolUse)"
for ev in ss ups ptu; do
  case "$ev" in ss) v="$ceil_ss" ;; ups) v="$ceil_ups" ;; ptu) v="$ceil_ptu" ;; esac
  b="$(bytes_of "$v")"
  [ "$b" -le 4000 ] && ok "ceiling: $ev under 4000 ($b bytes)" || bad "ceiling: $ev $b bytes"
  [[ "$v" != *"]]"* && "$v" != *"]\""* ]] && ok "ceiling: $ev has no stray bracket" || bad "ceiling: $ev stray bracket"
done
[[ "$ceil_ups" == *"GATE-CEILING-SENTINEL"* ]] && ok "ceiling: gate block kept under trim" || bad "ceiling: gate block lost"
[[ "$ceil_ss" == *"Policy \`secret-guard\`"* ]] \
  && ok "ceiling: must-fire summary kept under trim" || bad "ceiling: must-fire summary lost: $ceil_ss"
printf '%s' "$ceil_ptu" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
  && ok "ceiling: PostToolUse delta is valid JSON" || bad "ceiling: PostToolUse JSON broken: $ceil_ptu"
rm -f "$tmp/hq/.claude/hooks/hook-gate.sh" "$tmp/hq/.claude/hooks/policy-enforcement-gate.sh"
rm -f "$tmp/hq/core/policies/plain-hard-"*.md

# C: a corrupt index file falls back to the reminder and is moved aside.
bad_sid="bad$$"
run_event "$bad_sid" SessionStart >/dev/null
bad_file="$(index_file "$bad_sid" unscoped)"
printf '{"broken' > "$bad_file"
bad_out="$(run_event "$bad_sid" UserPromptSubmit)"
[ -n "$bad_out" ] && [[ "$bad_out" == *"policy-reminder"* ]] \
  && ok "corrupt index: reminder path still prints" || bad "corrupt index: silent ($bad_out)"
[ ! -e "$bad_file" ] || jq -e . "$bad_file" >/dev/null 2>&1 \
  && ok "corrupt index: bad file moved aside" || bad "corrupt index: bad file still in place"
bad_next="$(run_event "$bad_sid" SessionStart)"
[[ "$bad_next" == *"<policy-index>"* ]] && ok "corrupt index: next event rebuilds the index" || bad "corrupt index: no rebuild"

# Block-list tags count for must-fire.
cat > "$tmp/hq/core/policies/block-tags.md" <<'EOF'
---
id: block-tags
when: always
on: [SessionStart, UserPromptSubmit, PostToolUse]
enforcement: hard
tags:
  - vault
  - security
---
## Rule
Block tags. BLOCK-TAG-SENTINEL.
EOF
bt_out="$(run_event "bt$$" SessionStart)"
bt_rem="${bt_out#*<policy-reminder>}"
bt_rem="${bt_rem%%</policy-reminder>*}"
[[ "$bt_rem" == *"BLOCK-TAG-SENTINEL"* ]] && ok "must-fire: block-list tags" || bad "must-fire: block-list tags ignored"
rm -f "$tmp/hq/core/policies/block-tags.md"

# --- Review 3 fixes ---------------------------------------------------------

# Run one event with a 20 s limit; prints output, writes rc to $tmp/rl-rc
# (124 on timeout). Read it with rl_rc after the substitution.
run_limited() {
  local out="$tmp/rl-out.txt" pid waited=0
  : > "$out"
  ( run_event "$@" > "$out" ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 40 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done
  RL_RC=0
  if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    RL_RC=124
  fi
  wait "$pid" 2>/dev/null || true
  printf '%s\n' "$RL_RC" > "$tmp/rl-rc"
  cat "$out"
}
rl_rc() { cat "$tmp/rl-rc" 2>/dev/null || echo 1; }

# 1: the tail cut ends and fits at every ceiling from 1200 to 2000.
for n in 1 2 3 4 5 6; do
  cat > "$tmp/hq/core/policies/secret-cut-$n.md" <<EOF
---
id: secret-cut-$n
when: always
on: [SessionStart, UserPromptSubmit, PostToolUse]
enforcement: hard
---
## Rule
Never print secret value $n — the binding line for cut test $n stays long enough to matter here.
$big_text
EOF
done
cut_ok=1
cut_fit=1
cut_note=""
ceil=1200
while [ "$ceil" -le 2000 ]; do
  cut_out="$(HQ_POLICY_OUTPUT_CEILING_BYTES=$ceil run_limited "cut$ceil$$" SessionStart)"
  [ "$(rl_rc)" = 0 ] || { cut_ok=0; cut_note+=" timeout@$ceil"; }
  cut_b="$(bytes_of "$cut_out")"
  [ "$cut_b" -le "$ceil" ] || { cut_fit=0; cut_note+=" ${cut_b}>$ceil"; }
  ceil=$((ceil + 50))
done
[ "$cut_ok" = 1 ] && ok "tail cut: ends at every ceiling 1200-2000" || bad "tail cut:$cut_note"
[ "$cut_fit" = 1 ] && ok "tail cut: output at or under every ceiling" || bad "tail cut:$cut_note"
rm -f "$tmp/hq/core/policies/secret-cut-"*.md

# 2: many HARD rules are folded before any must-fire text is withheld.
mkdir -p "$tmp/parked2"
mv "$tmp/hq/core/policies/"*.md "$tmp/parked2/"
write_policy secret-guard hard "Never print a credential. BINDING-SECRET-SENTINEL applies before any other step."
write_policy recheck-secret hard "Recheck sentinel RECHECK-SECRET-SENTINEL stays binding."
for n in $(seq 1 300); do
  write_policy "fold-hard-$n" hard "Plain hard rule number $n for the fold-first check."
done
fold_out="$(run_limited "fold$$" SessionStart)"
fold_b="$(bytes_of "$fold_out")"
[[ "$fold_out" == *"BINDING-SECRET-SENTINEL"*"BINDING-SECRET-SENTINEL"* || "$fold_out" == *"> Never print a credential."* ]] \
  && [[ "$fold_out" == *"> Recheck sentinel RECHECK-SECRET-SENTINEL"* ]] \
  && ok "fold first: both must-fire bodies delivered with 300 HARD rules ($fold_b bytes)" \
  || bad "fold first: a body was withheld ($fold_b bytes)"
[ "$fold_b" -le 4000 ] && ok "fold first: under the ceiling" || bad "fold first: $fold_b bytes"
rm -f "$tmp/hq/core/policies/"*.md
mv "$tmp/parked2/"*.md "$tmp/hq/core/policies/"

# 3: must-fire full text once per session, a reference after, back after
# compaction.
rep_sid="rep$$"
write_policy rep-secret hard "Repeat sentinel REPEAT-SECRET-SENTINEL." check "[UserPromptSubmit, SessionStart]"
r1="$(run_event "$rep_sid" UserPromptSubmit)"
r2="$(run_event "$rep_sid" UserPromptSubmit)"
r3="$(run_event "$rep_sid" UserPromptSubmit)"
body_count=0
for r in "$r1" "$r2" "$r3"; do
  case "$r" in *"> Repeat sentinel REPEAT-SECRET-SENTINEL"*) body_count=$((body_count + 1)) ;; esac
done
[ "$body_count" = 1 ] && ok "repeat: full text once in three prompts" || bad "repeat: full text $body_count times"
[[ "$r2" == *"Still binding"*"rep-secret"* ]] \
  && ok "repeat: next prompt gives a one-line reference" || bad "repeat: no reference: $r2"
[[ "$r3" != *"rep-secret"* ]] \
  && ok "repeat: third prompt stays quiet like flag off" || bad "repeat: third prompt repeated: $r3"
# Bytes per prompt inside a session (after SessionStart, and again after a
# compaction): flag on must stay below flag off over three matching prompts.
prompt_bytes() {
  local sid="$1" total=0 out i
  for i in 1 2 3; do
    out="$(run_event "$sid" UserPromptSubmit)"
    total=$(( total + $(bytes_of "$out") ))
    [ -n "$out" ] || total=$(( total - 1 ))
  done
  printf '%s' "$total"
}
# Every-N re-emit is a separate, configured cost; keep it out of this count.
export HQ_POLICY_SESSION_INDEX_EVERY=25
on_s="pbon$$"
off_s="pboff$$"
run_event "$on_s" SessionStart >/dev/null
HQ_POLICY_SESSION_INDEX=0 run_event "$off_s" SessionStart >/dev/null
on_pb="$(prompt_bytes "$on_s")"
off_pb="$(HQ_POLICY_SESSION_INDEX=0 prompt_bytes "$off_s")"
[ "$on_pb" -lt "$off_pb" ] && ok "repeat: three prompts on=$on_pb bytes < off=$off_pb" \
  || bad "repeat: three prompts on=$on_pb not below off=$off_pb"
run_event "$on_s" SessionStart compact >/dev/null
HQ_POLICY_SESSION_INDEX=0 run_event "$off_s" SessionStart compact >/dev/null
on_pc="$(prompt_bytes "$on_s")"
off_pc="$(HQ_POLICY_SESSION_INDEX=0 prompt_bytes "$off_s")"
[ "$on_pc" -le "$off_pc" ] && ok "repeat: after compaction on=$on_pc bytes <= off=$off_pc" \
  || bad "repeat: after compaction on=$on_pc > off=$off_pc"
rc_out="$(run_event "$rep_sid" SessionStart compact)"
[[ "$rc_out" == *"> Repeat sentinel REPEAT-SECRET-SENTINEL"* ]] \
  && ok "repeat: compaction brings the full text back" || bad "repeat: no full text after compaction"
rcl_out="$(run_event "$rep_sid" SessionStart clear)"
[[ "$rcl_out" == *"> Repeat sentinel REPEAT-SECRET-SENTINEL"* ]] \
  && ok "repeat: clear brings the full text back" || bad "repeat: no full text after clear"
rm -f "$tmp/hq/core/policies/rep-secret.md"

# Lock release leaves another holder's lock alone.
(
  . "$tmp/hq/core/scripts/policy-session-index.sh"
  mkdir -p "$tmp/own.lock"
  printf '1\n' > "$tmp/own.lock/pid"
  policy_session_index_release_lock "$tmp/own.lock"
)
[ -d "$tmp/own.lock" ] && ok "lock: release keeps another holder's lock" || bad "lock: removed another holder's lock"
rm -rf "$tmp/own.lock"

# An uncreatable lock ends the wait instead of spinning. The event finishes.
lockfail_dir="$tmp/hq/workspace/orchestrator/policy-session-index"
mkdir -p "$lockfail_dir"
: > "$lockfail_dir/lockfail$$--unscoped.json.lock"
lockfail_start=$SECONDS
lockfail_out="$(HQ_POLICY_SESSION_INDEX=1 run_event "lockfail$$" SessionStart)"
lockfail_secs=$((SECONDS - lockfail_start))
rm -f "$lockfail_dir/lockfail$$--unscoped.json.lock"
[ "$lockfail_secs" -lt 15 ] && ok "lock: file at the lock path does not spin (${lockfail_secs}s)" \
  || bad "lock: file at the lock path took ${lockfail_secs}s"
[ -n "$lockfail_out" ] && ok "lock: uncreatable lock still emits" || bad "lock: uncreatable lock emitted nothing"

# A delta row is recorded, so rows past the relevance cap surface on later prompts.
capsid="capdelta$$"
HQ_POLICY_SESSION_INDEX=1 run_event "$capsid" SessionStart >/dev/null
mkdir -p "$tmp/cap-parked"
for parked in hot-style cold-style secret-guard; do
  [ -f "$tmp/hq/core/policies/$parked.md" ] && mv "$tmp/hq/core/policies/$parked.md" "$tmp/cap-parked/"
done
cap_saved="$tmp/cap-saved"
mkdir -p "$cap_saved"
for extra in "$tmp/hq/core/policies/"*.md; do
  [ -f "$extra" ] && mv "$extra" "$cap_saved/"
done
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
  write_policy "capsoft-$n" soft "Cap note $n." always "[UserPromptSubmit]"
done
capfresh="capfresh$$"
cap_all="$(HQ_POLICY_SESSION_INDEX=1 run_event "$capfresh" UserPromptSubmit
  HQ_POLICY_SESSION_INDEX=1 run_event "$capfresh" UserPromptSubmit
  HQ_POLICY_SESSION_INDEX=1 run_event "$capfresh" UserPromptSubmit)"
cap_missing=""
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
  [[ "$cap_all" == *"capsoft-$n"* ]] || cap_missing+=" $n"
done
[ -z "$cap_missing" ] && ok "delta: rows past the relevance cap surface on later prompts" \
  || bad "delta: never surfaced:$cap_missing"
rm -f "$tmp/hq/core/policies/"capsoft-*.md
for extra in "$cap_saved/"*.md "$tmp/cap-parked/"*.md; do
  [ -f "$extra" ] && mv "$extra" "$tmp/hq/core/policies/"
done

# Trial script reads both arms from policy-emit-stats.
trial_root="$tmp/trial"
mkdir -p "$trial_root/workspace/orchestrator/policy-emit-stats"
printf 't0\tSessionStart\t40\t2\n' > "$trial_root/workspace/orchestrator/policy-emit-stats/off-session.txt"
printf 't0\tSessionStart\t12\t2\tindex\nt1\tPostToolUse\t0\t0\tquiet\n' \
  > "$trial_root/workspace/orchestrator/policy-emit-stats/on-session.txt"
trial_out="$(python3 "$TRIAL" --root "$trial_root")"
[[ "$trial_out" == *"off-session	off	1	40"* ]] && ok "trial: flag-off session" || bad "trial: off row missing: $trial_out"
[[ "$trial_out" == *"on-session	on	2	12"* ]] && ok "trial: flag-on session" || bad "trial: on row missing: $trial_out"
[[ "$trial_out" == *"median_off_bytes=40"* && "$trial_out" == *"median_on_bytes=12"* ]] \
  && ok "trial: medians" || bad "trial: medians missing: $trial_out"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
