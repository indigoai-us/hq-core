#!/usr/bin/env bash
# hq-core: public
# policy-lifecycle US-003: staleness ordering in inject-policy-on-trigger.sh.
# Covers retired-sorts-last, exemption-holds-position,
# equal-specificity-fresh-first, and personal-soft-not-emitted.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh"

pass=0
fail() { echo "FAIL: $*" >&2; [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" >&2; exit 1; }
ok()   { pass=$((pass+1)); printf '  ok %s\n' "$1"; }

[ -f "$HOOK" ] || fail "hook not found at $HOOK"
command -v jq >/dev/null || fail "jq required"

# write_policy <file> <id> <enforcement> <extra-frontmatter-lines>
write_policy() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\nid: %s\ntitle: "%s"\nwhen: alpha\non: [UserPromptSubmit]\nenforcement: %s\n%s---\n\n## Rule\n\nRule text for %s.\n' \
    "$2" "$2" "$3" "$4" "$2" > "$1"
}

setup_tree() {
  ROOT="$(mktemp -d)"
  mkdir -p "$ROOT/core/policies" "$ROOT/personal/policies" \
    "$ROOT/workspace/orchestrator/policy-trigger-state" \
    "$ROOT/core/scripts/lib" "$ROOT/.claude/hooks"
  cat > "$ROOT/core/scripts/hook-lib.sh" <<'EOF'
hq_json_get() {
  local key="$1"
  jq -r --arg k "$key" '
    if $k == "hook_event_name" or $k == "session_id" or $k == "tool_name" or $k == "cwd" then
      .[$k] | if . == null or type == "object" or type == "array" then "" else tostring end
    else "" end
  '
}
EOF
  ln -s "$HQ_SRC/core/scripts/derive-trigger-facts.sh" "$ROOT/core/scripts/derive-trigger-facts.sh"
  cp "$HQ_SRC/core/scripts/lib/transcript-tail.sh" "$ROOT/core/scripts/lib/transcript-tail.sh"
  cp "$HQ_SRC/core/scripts/lib/trigger-fact-text.awk" "$ROOT/core/scripts/lib/trigger-fact-text.awk"
  printf '#!/bin/bash\nexit 0\n' > "$ROOT/core/scripts/eval-trigger.sh"
  chmod +x "$ROOT/core/scripts/"*.sh
  cp "$HOOK" "$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
}

run_hook() {
  local input
  input="$(jq -cn --arg sid "stale-$$-$RANDOM" --arg cwd "$ROOT" \
    '{session_id:$sid,hook_event_name:"UserPromptSubmit",cwd:$cwd,prompt:"alpha"}')"
  OUT="$(env HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" HQ_POLICY_STALE_TODAY=2026-10-07 "$@" \
    bash "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" <<<"$input" 2>/dev/null || true)"
}

# order_of <slug>: 1-based position of the slug among emitted policy names.
order_of() {
  printf '%s\n' "$OUT" | grep -oE 'Policy `[^`]+`' | sed 's/^Policy `//; s/`$//' \
    | awk -v s="$1" '$0==s { print NR; found=1; exit } END { if (!found) print 0 }'
}

before() { # before <a> <b>: a emitted strictly ahead of b
  local a b; a="$(order_of "$1")"; b="$(order_of "$2")"
  [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ]
}

# ── retired-sorts-last ────────────────────────────────────────────────────
setup_tree
write_policy "$ROOT/core/policies/a-superseded.md" a-superseded soft $'status: superseded\ncreated: 2026-10-06\n'
write_policy "$ROOT/core/policies/b-fresh.md" b-fresh soft $'created: 2026-10-01\n'
write_policy "$ROOT/core/policies/c-older.md" c-older soft $'created: 2025-01-01\n'
write_policy "$ROOT/core/policies/d-retired.md" d-retired soft $'status: retired\ncreated: 2026-10-06\n'
run_hook
before b-fresh a-superseded || fail "retired-sorts-last: superseded policy was not ordered after the fresh one"
before c-older a-superseded || fail "retired-sorts-last: superseded policy was not ordered after an older live one"
[ "$(order_of d-retired)" = 0 ] || fail "retired-sorts-last: retired policy was injected"
grep -q 'id: d-retired' "$ROOT/core/policies/d-retired.md" || fail "retired policy file was moved or deleted"
ok "retired-sorts-last"
rm -rf "$ROOT"

# ── equal-specificity-fresh-first ─────────────────────────────────────────
setup_tree
write_policy "$ROOT/core/policies/a-old.md" a-old soft $'created: 2020-01-01\n'
write_policy "$ROOT/core/policies/b-new.md" b-new soft $'created: 2026-10-01\n'
write_policy "$ROOT/core/policies/c-retire-when.md" c-retire-when soft $'created: 2026-10-01\nretire_when: tool ships the fix\n'
run_hook
before b-new a-old || fail "equal-specificity-fresh-first: newer created did not sort first"
before b-new c-retire-when || fail "equal-specificity-fresh-first: retire_when penalty not applied"
# A recent retrieval in the durable ledger makes the old policy fresh again.
printf '{"policy":"a-old","session":"s","ts":"2026-10-07T00:00:00Z","via":"qmd"}\n' \
  > "$ROOT/workspace/orchestrator/policy-retrieval-ledger.jsonl"
run_hook
before a-old b-new || fail "equal-specificity-fresh-first: recent retrieval did not make the policy fresh"
ok "equal-specificity-fresh-first"
rm -rf "$ROOT"

# ── exemption-holds-position ──────────────────────────────────────────────
setup_tree
write_policy "$ROOT/core/policies/a-cred-stale.md" a-cred-stale hard $'created: 2020-01-01\ntags: [credential, aws]\n'
write_policy "$ROOT/core/policies/b-plain-stale.md" b-plain-stale hard $'created: 2020-01-01\n'
write_policy "$ROOT/core/policies/c-hard-fresh.md" c-hard-fresh hard $'created: 2026-10-06\n'
write_policy "$ROOT/core/policies/d-always-stale.md" d-always-stale soft $'created: 2020-01-01\ninject: always\n'
write_policy "$ROOT/core/policies/e-soft-fresh.md" e-soft-fresh soft $'created: 2026-10-06\n'
run_hook
[ "$(order_of a-cred-stale)" = 1 ] || fail "exemption-holds-position: credential hard rule moved from position 1"
before c-hard-fresh b-plain-stale || fail "exemption-holds-position: non-exempt stale hard rule was not reordered"
before d-always-stale e-soft-fresh || fail "exemption-holds-position: inject: always policy moved"
ok "exemption-holds-position"
rm -rf "$ROOT"

# ── personal-soft-not-emitted ─────────────────────────────────────────────
setup_tree
write_policy "$ROOT/personal/policies/p-soft.md" p-soft soft ''
write_policy "$ROOT/personal/policies/p-unset.md" p-unset unset ''
write_policy "$ROOT/personal/policies/p-hard.md" p-hard hard ''
write_policy "$ROOT/core/policies/k-soft.md" k-soft soft ''
run_hook
[ "$(order_of p-soft)" = 0 ] || fail "personal-soft-not-emitted: personal soft policy was injected"
[ "$(order_of p-unset)" = 0 ] || fail "personal-soft-not-emitted: personal unset policy was injected"
[ "$(order_of p-hard)" -gt 0 ] || fail "personal-soft-not-emitted: personal hard policy was dropped"
[ "$(order_of k-soft)" -gt 0 ] || fail "personal-soft-not-emitted: core soft policy was dropped"
run_hook HQ_INJECT_PERSONAL_SOFT=1
[ "$(order_of p-soft)" -gt 0 ] || fail "personal-soft-not-emitted: HQ_INJECT_PERSONAL_SOFT=1 did not restore it"
ok "personal-soft-not-emitted"
rm -rf "$ROOT"

echo "PASS: $pass/4 inject-policy-on-trigger staleness cases"
