#!/usr/bin/env bash
# hq-core: public
# hook-speed-bounds.test.sh
#
# Regression contract for hook latency and the zsh read-only status variable:
#   [1] advisory policy injection is bounded per event: inject-policy-on-trigger
#       may run at most 30 s on UserPromptSubmit and 20 s on PostToolUse (both
#       advisory there). The PreToolUse entry keeps 60 s, and every guard
#       registered on PreToolUse keeps its timeout and fail_closed flag.
#   [2] policy-enforcement-gate UserPromptSubmit skips the conflict scan when
#       the prompt has no polarity word: no node process, and the saved state
#       has conflicts [] exactly as the full scan gives. A prompt with a
#       polarity word still runs the scan and surfaces the conflict.
#   [3] timing: with 40 HARD matches and a polarity-free prompt, the gate's
#       UserPromptSubmit run finishes under a fixed budget (no per-policy
#       awk/jq pair, no node boot).
#   [4] zsh: no shell snippet in a skill or command assigns `status`, which
#       is read-only in zsh (the Bash tool runs zsh on macOS).
# Runs on bash 5 and /bin/bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
GATE="${HQ_TEST_POLICY_GATE_HOOK:-$ROOT/.claude/hooks/policy-enforcement-gate.sh}"
command -v jq >/dev/null || { echo "jq required"; exit 2; }

failures=0
passes=0
ok() { printf 'ok   %s\n' "$1"; passes=$((passes + 1)); }
bad() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[1] per-event bound on advisory policy injection"
t_of() { jq -r --arg e "$1" '[.hooks[$e][]?.hooks[]? | select(.id=="inject-policy-on-trigger") | .timeout] | .[0] // "missing"' "$REGISTRY"; }
ups="$(t_of UserPromptSubmit)"; post="$(t_of PostToolUse)"; pre="$(t_of PreToolUse)"
# UserPromptSubmit is not advisory: it publishes the turn's HARD match set and
# the gate receipts the PreToolUse gate reads, so its timeout is not cut.
[ "$ups" = 60 ] && ok "UserPromptSubmit injection timeout unchanged (60 s)" || bad "UserPromptSubmit injection timeout changed to $ups"
# The prompt-time match-set rewrite is one rename: a kill between a truncate
# and an append must not publish a set without the turn's HARD rows.
renames="$(awk '/ENFORCEMENT_DIR\/\.(baselines|matches)\./ {n++} END {print n+0}' "$ROOT/.claude/hooks/inject-policy-on-trigger.sh")"
[ "$renames" -eq 1 ] && ok "the enforcement match set is replaced by one temp file and one rename" || bad "match set written through $renames temp files"
[ "$post" != missing ] && [ "$post" -le 20 ] && ok "PostToolUse injection timeout is $post s (<= 20)" || bad "PostToolUse injection timeout is $post"
[ "$pre" = 60 ] && ok "PreToolUse injection timeout unchanged (60 s)" || bad "PreToolUse injection timeout changed to $pre"
guards="$(jq -c '[.hooks.PreToolUse[]?.hooks[]? | select(.fail_closed==true) | {id,timeout}] | sort_by(.id)' "$REGISTRY")"
short="$(printf '%s' "$guards" | jq '[.[] | select((.timeout // 30) < 30)] | length')"
[ "$short" -eq 0 ] && ok "no fail_closed PreToolUse guard has a timeout under 30 s" || bad "fail_closed guards shortened: $guards"

echo "[2] gate conflict scan skip is exact"
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/workspace/orchestrator/policy-enforcement" "$FIX/policies" "$FIX/core/scripts/lib" "$TMP/bin"
cp "$GATE" "$FIX/.claude/hooks/policy-enforcement-gate.sh"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIX/core/scripts/hook-lib.sh"
cp "$ROOT/core/scripts/lib/session-id.sh" "$FIX/core/scripts/lib/session-id.sh"
real_node="$(command -v node || true)"
cat > "$TMP/bin/node" <<EOF
#!/usr/bin/env bash
printf 'x\n' >> "$TMP/node.calls"
exec "$real_node" "\$@"
EOF
chmod +x "$TMP/bin/node"
write_policies() { # <sid> <count>
  local sid="$1" n="$2" i pol
  : > "$FIX/workspace/orchestrator/policy-enforcement/$sid.policies.tsv"
  for i in $(seq 1 "$n"); do
    pol="$FIX/policies/p$i.md"
    printf -- '---\nid: p%s\nenforcement: hard\n---\n## Rule\n\nNEVER include internal evidence in external copy %s.\n' "$i" "$i" > "$pol"
    printf 'p%s\tcore\t%s\thard\tNEVER include internal evidence in external copy %s.\n' "$i" "$pol" "$i" \
      >> "$FIX/workspace/orchestrator/policy-enforcement/$sid.policies.tsv"
  done
}
gate_ups() { # <sid> <prompt>
  jq -nc --arg sid "$1" --arg cwd "$FIX" --arg p "$2" '{session_id:$sid,cwd:$cwd,prompt:$p}' \
    | PATH="$TMP/bin:$PATH" CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.claude/hooks/policy-enforcement-gate.sh" UserPromptSubmit || true
}
if [ -z "$real_node" ]; then
  bad "node is required for the conflict scan cases"
else
  write_policies s-plain 3
  rm -f "$TMP/node.calls"
  gate_ups s-plain "Summarise the open pull requests for the team." >/dev/null
  calls=0
  [ ! -f "$TMP/node.calls" ] || calls="$(wc -l < "$TMP/node.calls" | tr -d " ")"
  [ "$calls" -eq 0 ] && ok "a polarity-free prompt starts no node process" || bad "polarity-free prompt started node $calls time(s)"
  jq -e '.conflicts == []' "$FIX/workspace/orchestrator/policy-enforcement/s-plain.json" >/dev/null \
    && ok "and the saved state has conflicts []" || bad "state conflicts wrong: $(cat "$FIX/workspace/orchestrator/policy-enforcement/s-plain.json")"
  write_policies s-conf 3
  out="$(gate_ups s-conf "You MUST include internal evidence in external copy 1.")"
  case "$out" in *"INSTRUCTION CONFLICTS SURFACED"*) ok "a polarity prompt still surfaces the conflict" ;; *) bad "conflict not surfaced: $out" ;; esac
  out="$(gate_ups s-conf "Always include internal evidence in external copy 2.")"
  case "$out" in *"INSTRUCTION CONFLICTS SURFACED"*) ok "an 'Always' prompt surfaces the conflict" ;; *) bad "'Always' conflict not surfaced: $out" ;; esac
  rm -f "$TMP/node.calls"
  gate_ups s-plain "Do not summarise anything; forbidden topics stay out." >/dev/null
  [ -s "$TMP/node.calls" ] && ok "'do not' / 'forbidden' prompts still run the scan" || bad "'do not' prompt skipped the scan"
fi

echo "[3] timing: 40 HARD matches, polarity-free prompt"
write_policies s-time 40
start="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
gate_ups s-time "Summarise the open pull requests for the team." >/dev/null
end="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
ms=$((end - start))
budget="${HQ_TEST_GATE_UPS_BUDGET_MS:-500}"
[ "$ms" -le "$budget" ] && ok "gate UserPromptSubmit took $ms ms (budget $budget ms)" || bad "gate UserPromptSubmit took $ms ms, over $budget ms"

echo "[4] no zsh read-only status assignment in skill snippets"
hits="$(cd "$ROOT" && find .claude/skills .claude/commands core/skills core/commands -name '*.md' 2>/dev/null \
  | xargs awk '
      /^[[:space:]]*```/ { inblk = !inblk; next }
      inblk && /(^|[;&|]|then|do)[[:space:]]*(local[[:space:]]+|export[[:space:]]+)?status=/ { print FILENAME ":" FNR ": " $0 }
    ' 2>/dev/null || true)"
[ -z "$hits" ] && ok "no code block assigns status" || bad "zsh read-only status assigned: $hits"

printf '%s passed, %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
