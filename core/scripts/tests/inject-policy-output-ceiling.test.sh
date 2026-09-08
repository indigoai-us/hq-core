#!/usr/bin/env bash
# hq-core: public
# inject-policy-output-ceiling.test.sh (2026-09-07)
#
# Claude Code persists any hook stdout above ~10,000 bytes to a file and shows
# the model a ~2 KB preview; the rest is lost for that turn. These tests pin:
#   [1] the loader's default budgets sit under the ceiling (fails if raised)
#   [2] an oversize corpus of hard policies still emits under the ceiling, and
#       says so rather than truncating silently
#   [3] hard policies are ranked ahead of soft ones under the count cap
#   [4] the company-bind digest default byte budget sits under the ceiling
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
CEILING=8000
HOST_LIMIT=10000
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

echo "[1] default budgets under the host ceiling"
hb="$(grep -oE 'HQ_POLICY_HARD_BUDGET_BYTES:-[0-9]+' "$HOOK" | grep -oE '[0-9]+$')"
oc="$(grep -oE 'HQ_POLICY_OUTPUT_CEILING_BYTES:-[0-9]+' "$HOOK" | grep -oE '[0-9]+$')"
bb="$(grep -oE 'HQ_COMPANY_BIND_POLICY_BYTES:-[0-9]+' "$ROOT/core/scripts/hq-session.sh" | grep -oE '[0-9]+$')"
[ -n "$hb" ] && [ "$hb" -lt "$CEILING" ] || fail "HARD_BUDGET default $hb must be < $CEILING"
[ -n "$oc" ] && [ "$oc" -le "$CEILING" ] || fail "OUTPUT_CEILING default $oc must be <= $CEILING"
[ -n "$bb" ] && [ "$bb" -lt "$CEILING" ] || fail "bind digest byte budget default $bb must be < $CEILING"

# --- fixture (mirrors .claude/hooks/tests/inject-policy-on-trigger-emit.test.sh)
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/core/policies" "$FX/personal/policies" "$FX/workspace/orchestrator/policy-trigger-state" "$FX/core/scripts" "$FX/.claude/hooks"
cat > "$FX/core/scripts/hook-lib.sh" <<'LIB'
hq_json_get() { local key="$1"; jq -r --arg k "$key" 'if $k == "hook_event_name" or $k == "session_id" or $k == "tool_name" or $k == "cwd" then .[$k] | if . == null or type == "object" or type == "array" then "" else tostring end else "" end'; }
LIB
printf '#!/bin/bash\necho always\n' > "$FX/core/scripts/derive-trigger-facts.sh"
printf '#!/bin/bash\nexit 0\n' > "$FX/core/scripts/eval-trigger.sh"
chmod +x "$FX/core/scripts/"*.sh
cp "$HOOK" "$FX/.claude/hooks/"
wp() { # <file> <id> <enforcement> <rule-text>
  printf -- '---\nid: %s\ntitle: "%s"\nscope: test\nwhen: always\non: [UserPromptSubmit]\nenforcement: %s\n---\n\n## Rule\n\n%s\n' "$2" "$2" "$3" "$4" > "$1"
}
run() { # <extra env...>
  local input; input="$(jq -cn --arg sid "ceil-$$-$RANDOM" --arg cwd "$FX" '{session_id:$sid,hook_event_name:"UserPromptSubmit",cwd:$cwd,prompt:"x"}')"
  env HQ_ROOT="$FX" CLAUDE_PROJECT_DIR="$FX" "$@" bash "$FX/.claude/hooks/inject-policy-on-trigger.sh" <<<"$input" 2>/dev/null
}

echo "[2] oversize hard corpus emits under the ceiling, non-silently"
big="$(printf 'HARDBODY %.0s' $(seq 1 150))"   # ~1.4 KB body, under HARD_MAX
for n in $(seq 1 16); do wp "$FX/core/policies/hard-$(printf '%02d' $n).md" "hard-$(printf '%02d' $n)" hard "$big"; done
# 2a. defaults: the full-text budget alone keeps the emission under the ceiling
out="$(run)"
bytes="$(printf '%s' "$out" | wc -c | tr -d ' ')"
[ "$bytes" -le "$CEILING" ] || fail "default emission is $bytes bytes, over the $CEILING ceiling"
grep -q 'Output ceiling of' <<<"$out" && fail "defaults should not need the ceiling fallback: $out"
# 2b. an operator who raises the budget past the ceiling still gets a deliverable reminder
out="$(run HQ_POLICY_HARD_BUDGET_BYTES=30000)"
bytes="$(printf '%s' "$out" | wc -c | tr -d ' ')"
[ "$bytes" -le "$CEILING" ] || fail "emission is $bytes bytes, over the $CEILING ceiling"
[ "$bytes" -lt "$HOST_LIMIT" ] || fail "emission is $bytes bytes, host would truncate"
grep -q 'Output ceiling of' <<<"$out" || fail "over-ceiling fallback must be announced: $out"
grep -q '^> Policy `hard-01`' <<<"$out" || fail "policies must still be listed as summaries"
grep -q 'HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY HARDBODY ' <<<"$out" && fail "full bodies must be dropped in the fallback"
grep -q '</policy-reminder>' <<<"$out" || fail "reminder block must close"
# 2c. the ledger recorded each slug exactly once despite the double emission
led="$(ls "$FX/workspace/orchestrator/policy-trigger-state/"*.txt | tail -1)"
[ "$(grep -c '^hard-01$' "$led")" = 1 ] || fail "hard-01 recorded $(grep -c '^hard-01$' "$led") times in the ledger"

echo "[3] hard policies rank ahead of soft under the cap"
rm -f "$FX/core/policies/"*.md
for n in $(seq 1 6); do wp "$FX/core/policies/a-soft-$n.md" "a-soft-$n" soft "soft rule $n"; done
wp "$FX/core/policies/z-hard.md" "z-hard" hard "ZHARD rule"
out="$(run HQ_SESSION_POLICY_CAP=3)"
grep -q 'z-hard' <<<"$out" || fail "hard policy lost its slot to earlier-sorting soft policies: $out"
first="$(grep -m1 '^> Policy `' <<<"$out")"
case "$first" in *'z-hard'*) ;; *) fail "hard policy should be listed first, got: $first" ;; esac

echo "inject-policy-output-ceiling: ok"

# ---- index mode (2026-09-07) -------------------------------------------------
echo "[4] index mode: no count cap by default — 40 matching policies all listed"
rm -f "$FX/core/policies/"*.md
for n in $(seq 1 40); do wp "$FX/core/policies/idx-$(printf '%02d' $n).md" "idx-$(printf '%02d' $n)" soft "index rule $n"; done
out="$(run)"
listed="$(grep -c '^> Policy `idx-' <<<"$out")"
[ "$listed" = 40 ] || fail "expected all 40 index lines, got $listed: $(grep -c . <<<"$out") lines"
grep -q 'Session policy cap withheld' <<<"$out" && fail "no count-cap notice in index mode"
bytes="$(printf '%s' "$out" | wc -c | tr -d ' ')"; [ "$bytes" -le "$CEILING" ] || fail "index over ceiling: $bytes"
grep -q 'This is an index' <<<"$out" || fail "retrieval instruction missing"

echo "[5] index mode: explicit HQ_SESSION_POLICY_CAP restores the legacy count cap"
out="$(run HQ_SESSION_POLICY_CAP=5)"
[ "$(grep -c '^> Policy `idx-' <<<"$out")" = 5 ] || fail "legacy cap not honoured"
grep -q 'withheld 35 policies' <<<"$out" || fail "legacy withheld notice missing: $out"

echo "[6] under a tight budget the reactive hard rule gets full text and the baseline hard rule is an index line"
rm -f "$FX/core/policies/"*.md
wp "$FX/core/policies/base-hard.md" base-hard hard "BASEHARD summary line"
printf -- '---\nid: react-hard\ntitle: "react-hard"\nscope: test\nwhen: always\non: [UserPromptSubmit]\nenforcement: hard\n---\n\n## Rule\n\nREACTHARD summary line\n\nREACTHARD body detail.\n' > "$FX/core/policies/react-hard.md"
printf -- '---\nid: base-hard\ntitle: "base-hard"\nscope: test\nwhen: always\non: [SessionStart]\nenforcement: hard\n---\n\n## Rule\n\nBASEHARD summary line\n\nBASEHARD body detail.\n' > "$FX/core/policies/base-hard.md"
out="$(run HQ_POLICY_HARD_BUDGET_BYTES=60)"
grep -q 'REACTHARD body detail' <<<"$out" || fail "reactive hard rule should carry full text: $out"
grep -q 'BASEHARD body detail' <<<"$out" && fail "baseline hard rule should be an index line only: $out"
grep -q '^> Policy `base-hard` applies here: BASEHARD summary line  \[HARD · core\]' <<<"$out" || fail "hard index line format: $out"

echo "[7] specificity: a trigger matching more facts ranks first within its tier"
rm -f "$FX/core/policies/"*.md
# facts stub returns 'always' only, so key both on 'always' plus tokens; use the
# derive stub to emit richer facts for this case
printf '#!/bin/bash\necho "always deploy vercel indigo"\n' > "$FX/core/scripts/derive-trigger-facts.sh"
wp "$FX/core/policies/a-generic.md" a-generic soft "GENERIC deploy rule"
sed -i.bak 's/^when: always$/when: deploy/' "$FX/core/policies/a-generic.md"
wp "$FX/core/policies/z-specific.md" z-specific soft "SPECIFIC deploy rule"
sed -i.bak 's/^when: always$/when: deploy \&\& vercel \&\& indigo/' "$FX/core/policies/z-specific.md"
rm -f "$FX/core/policies/"*.bak
out="$(run)"
first="$(grep -m1 '^> Policy `' <<<"$out")"
case "$first" in *'z-specific'*) ;; *) fail "more specific trigger should rank first, got: $first" ;; esac
printf '#!/bin/bash\necho always\n' > "$FX/core/scripts/derive-trigger-facts.sh"

echo "[8] retired policies and sync conflict twins never inject"
rm -f "$FX/core/policies/"*.md
wp "$FX/core/policies/live.md" live soft "LIVE rule"
printf -- '---\nid: gone\ntitle: "gone"\nscope: test\nwhen: always\non: [UserPromptSubmit]\nenforcement: hard\nstatus: retired\n---\n\n## Rule\n\nGONE rule\n' > "$FX/core/policies/gone.md"
wp "$FX/core/policies/live.md.conflict-2026-08-01T00-00-00Z-abc123.md" live-twin soft "TWIN rule"
out="$(run)"
grep -q 'LIVE rule' <<<"$out" || fail "live policy missing"
grep -q 'GONE rule' <<<"$out" && fail "retired policy injected"
grep -q 'TWIN rule' <<<"$out" && fail "conflict twin injected"

echo "inject-policy-output-ceiling (index mode): ok"
