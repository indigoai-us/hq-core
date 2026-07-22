#!/usr/bin/env bash
# hq-core: public
# US-406: inject-policy-on-trigger.sh — HQ_POLICY_EMIT=tsv shape, default-mode
# byte identity, company-wins precedence, HQ_POLICY_COMPANY override.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh"
FIXTURE_DIR="$HQ_SRC/core/scripts/tests/fixtures"
FIXTURE_PROSE="$FIXTURE_DIR/inject-policy-default-prose.fixture.txt"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { pass=$((pass+1)); printf '  ok %s\n' "$1"; }

[ -f "$HOOK" ] || fail "hook not found at $HOOK"
command -v jq >/dev/null || fail "jq required"

# write_policy <file> <id> <when> <on> <enforcement|EMPTY> <rule-text>
write_policy() {
  local enf_line=""
  if [ -n "${5:-}" ]; then
    enf_line="enforcement: $5"
  fi
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
---
id: $2
title: "$2"
scope: test
when: $3
on: $4
${enf_line}
---

## Rule

$6
EOF
}

setup_tree() {
  ROOT="$(mktemp -d)"
  mkdir -p "$ROOT/core/policies" "$ROOT/companies/indigo/policies" \
    "$ROOT/personal/policies" \
    "$ROOT/workspace/orchestrator/policy-trigger-state" \
    "$ROOT/core/scripts" "$ROOT/.claude/hooks"
  # Minimal helpers the hook sources
  cat > "$ROOT/core/scripts/hook-lib.sh" <<'EOF'
hq_json_get() {
  local key="$1"
  printf '%s' "$STDIN_JSON" | jq -r --arg k "$key" '
    if $k == "hook_event_name" then .hook_event_name // empty
    elif $k == "session_id" then .session_id // empty
    elif $k == "tool_name" then .tool_name // empty
    elif $k == "cwd" then .cwd // empty
    else empty end
  '
}
EOF
  printf '#!/bin/bash\necho always\n' > "$ROOT/core/scripts/derive-trigger-facts.sh"
  printf '#!/bin/bash\nexit 0\n' > "$ROOT/core/scripts/eval-trigger.sh"
  chmod +x "$ROOT/core/scripts/"*.sh
  cp "$HOOK" "$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
  HOOK_COPY="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
}

run_hook() {
  # run_hook <cwd> <event> <prompt> [env assignments...]
  local cwd="$1" event="$2" prompt="$3"
  shift 3 || true
  local sid="emit-test-$$-$RANDOM"
  local input
  input="$(jq -cn --arg sid "$sid" --arg cwd "$cwd" --arg p "$prompt" --arg e "$event" \
    '{session_id:$sid,hook_event_name:$e,cwd:$cwd,prompt:$p}')"
  env HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" "$@" \
    bash "$HOOK_COPY" <<<"$input" 2>/dev/null || true
}

# ── Case 1: tsv line shape ───────────────────────────────────────────────────
setup_tree
write_policy "$ROOT/core/policies/shape-me.md" \
  "shape-me" "always" "[SessionStart]" "hard" "SHAPE_RULE_TEXT here."
OUT="$(run_hook "$ROOT/companies/indigo" "UserPromptSubmit" "hello" HQ_POLICY_EMIT=tsv)"
# single line, five tab-separated fields, no policy-reminder markup
line_count="$(printf '%s\n' "$OUT" | grep -c . || true)"
[ "$line_count" -ge 1 ] || fail "tsv: expected at least one line, got: $OUT"
first="$(printf '%s\n' "$OUT" | head -n1)"
printf '%s' "$first" | grep -q $'\t' || fail "tsv: no tabs in line: $first"
# field count
fc="$(printf '%s' "$first" | awk -F'\t' '{print NF}')"
[ "$fc" = "5" ] || fail "tsv: expected 5 fields got $fc: $first"
printf '%s' "$OUT" | grep -q '<policy-reminder>' && fail "tsv: must not emit prose markup"
slug="$(printf '%s' "$first" | cut -f1)"
scope="$(printf '%s' "$first" | cut -f2)"
path="$(printf '%s' "$first" | cut -f3)"
enf="$(printf '%s' "$first" | cut -f4)"
rule="$(printf '%s' "$first" | cut -f5)"
[ "$slug" = "shape-me" ] || fail "tsv slug=$slug"
[ "$scope" = "core" ] || fail "tsv scope=$scope"
[ -n "$path" ] || fail "tsv path empty"
[ "$enf" = "hard" ] || fail "tsv enf=$enf (expected hard)"
printf '%s' "$rule" | grep -q "SHAPE_RULE_TEXT" || fail "tsv rule missing text"
ok "tsv five-field line shape"

# ── Case 2: enforcement hard vs unset ────────────────────────────────────────
write_policy "$ROOT/core/policies/no-enf.md" \
  "no-enf" "always" "[SessionStart]" "" "NO_ENF_RULE"
OUT2="$(run_hook "$ROOT/companies/indigo" "UserPromptSubmit" "hello" HQ_POLICY_EMIT=tsv)"
printf '%s\n' "$OUT2" | grep -E $'^shape-me\t' | grep -q $'\thard\t' \
  || fail "hard enforcement not emitted: $OUT2"
printf '%s\n' "$OUT2" | grep -E $'^no-enf\t' | grep -q $'\tunset\t' \
  || fail "unset enforcement not emitted: $OUT2"
ok "enforcement hard and unset"

# ── Case 3: default mode byte identity vs fixture ────────────────────────────
# Checked-in fixture is the exact prose block for a single soft SessionStart
# policy with rule text "FIXTURE_RULE_MARKER prose." — path-agnostic.
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/core/policies/fixture-pol.md" \
  "fixture-pol" "always" "[SessionStart]" "soft" "FIXTURE_RULE_MARKER prose."
DEFAULT_OUT="$(run_hook "$ROOT/companies/indigo" "UserPromptSubmit" "anything")"
mkdir -p "$FIXTURE_DIR"
# Command substitution strips trailing newlines; the hook emits one final \n
# after </policy-reminder>. Compare the stable body (no trailing newline).
EXPECTED=$'<policy-reminder>\n> Policy `fixture-pol` applies here: FIXTURE_RULE_MARKER prose.\n> Read the full rule(s) at `core/policies/{slug}.md` if you need rationale.\n</policy-reminder>'
# Checked-in fixture includes the trailing newline the hook prints on stdout.
printf '%s\n' "$EXPECTED" > "$FIXTURE_PROSE"
if [ "$DEFAULT_OUT" != "$EXPECTED" ]; then
  echo "got:" >&2
  printf '%s' "$DEFAULT_OUT" | od -c | head -20 >&2
  echo "expected:" >&2
  printf '%s' "$EXPECTED" | od -c | head -20 >&2
  fail "default mode not byte-identical to fixture at $FIXTURE_PROSE"
fi
# On-disk fixture must match hook stdout including the final newline; rebuild
# full stdout via printf '%s\n' for cmp against the file.
cmp -s <(printf '%s\n' "$DEFAULT_OUT") "$FIXTURE_PROSE" \
  || fail "default mode diverged from on-disk fixture"
ok "default mode byte-identical to fixture"

# ── Case 4: company wins on colliding id (tsv) ───────────────────────────────
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/core/policies/collide-me.md" \
  "collide-me" "always" "[SessionStart]" "hard" "CORE_COPY_MARKER"
write_policy "$ROOT/companies/indigo/policies/collide-me.md" \
  "collide-me" "always" "[SessionStart, UserPromptSubmit]" "soft" "COMPANY_COPY_MARKER"
OUT4="$(run_hook "$ROOT/companies/indigo" "UserPromptSubmit" "x" HQ_POLICY_EMIT=tsv)"
n="$(printf '%s\n' "$OUT4" | grep -c $'^collide-me\t' || true)"
[ "$n" = "1" ] || fail "collision: expected 1 line got $n: $OUT4"
printf '%s\n' "$OUT4" | grep -E $'^collide-me\tcompany\t' | grep -q COMPANY_COPY_MARKER \
  || fail "company copy did not win: $OUT4"
printf '%s\n' "$OUT4" | grep -q CORE_COPY_MARKER && fail "core copy leaked: $OUT4"
ok "company wins colliding id in tsv"

# ── Case 5: HQ_POLICY_COMPANY override with CWD outside companies/ ───────────
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/companies/indigo/policies/co-only.md" \
  "co-only" "always" "[SessionStart]" "soft" "INDIGO_ONLY_MARKER"
# CWD is root (no companies/* match) but HQ_POLICY_COMPANY=indigo
OUT5="$(run_hook "$ROOT" "UserPromptSubmit" "x" HQ_POLICY_EMIT=tsv HQ_POLICY_COMPANY=indigo)"
printf '%s\n' "$OUT5" | grep -q INDIGO_ONLY_MARKER \
  || fail "HQ_POLICY_COMPANY override failed: $OUT5"
printf '%s\n' "$OUT5" | grep -E $'^co-only\tcompany\t' >/dev/null \
  || fail "scope not company: $OUT5"
ok "HQ_POLICY_COMPANY override outside companies/"

echo
echo "PASS ($pass assertions)"
