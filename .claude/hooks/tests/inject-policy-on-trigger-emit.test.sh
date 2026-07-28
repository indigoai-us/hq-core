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
fail() {
  if [ -n "${ROOT:-}" ] && [ -f "$ROOT/.last-run-hook-status" ] \
    && [ ! -s "$ROOT/.last-run-hook-output" ]; then
    local hook_status
    hook_status="$(cat "$ROOT/.last-run-hook-status")"
    if [ "$hook_status" != "0" ]; then
      echo "FAIL: run_hook returned empty output; hook exit status $hook_status: $*" >&2
      exit 1
    fi
  fi
  echo "FAIL: $*" >&2
  exit 1
}
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
  jq -r --arg k "$key" '
    if $k == "hook_event_name" or $k == "session_id" or $k == "tool_name" or $k == "cwd" then
      .[$k] | if . == null or type == "object" or type == "array" then "" else tostring end
    else "" end
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
  local status=0
  env HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" "$@" \
    bash "$HOOK_COPY" <<<"$input" >"$ROOT/.last-run-hook-output" 2>/dev/null || status=$?
  printf '%s\n' "$status" > "$ROOT/.last-run-hook-status"
  cat "$ROOT/.last-run-hook-output"
}

# run_hook_sid <cwd> <event> <prompt> <session_id> [env assignments...]
# Like run_hook but with a caller-chosen session_id, so a matching
# workspace/sessions/<sid>/meta.yaml can be staged first (US-004).
run_hook_sid() {
  local cwd="$1" event="$2" prompt="$3" sid="$4"
  shift 4 || true
  local input
  input="$(jq -cn --arg sid "$sid" --arg cwd "$cwd" --arg p "$prompt" --arg e "$event" \
    '{session_id:$sid,hook_event_name:$e,cwd:$cwd,prompt:$p}')"
  local status=0
  env HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" "$@" \
    bash "$HOOK_COPY" <<<"$input" >"$ROOT/.last-run-hook-output" 2>/dev/null || status=$?
  printf '%s\n' "$status" > "$ROOT/.last-run-hook-status"
  cat "$ROOT/.last-run-hook-output"
}

# write_meta <session_id> <company_slug>  — stage a well-formed session meta.
# write_meta_raw <session_id> <literal-body> — stage arbitrary (e.g. malformed).
write_meta() {
  mkdir -p "$ROOT/workspace/sessions/$1"
  printf 'session_id: %s\ncompany_slug: "%s"\n' "$1" "$2" > "$ROOT/workspace/sessions/$1/meta.yaml"
}
write_meta_raw() {
  mkdir -p "$ROOT/workspace/sessions/$1"
  printf '%s\n' "$2" > "$ROOT/workspace/sessions/$1/meta.yaml"
}

# ── Case 1: tsv line shape ───────────────────────────────────────────────────
setup_tree
STUB_VALUE="$(
  STDIN_JSON='{"hook_event_name":"from-variable"}' \
    bash -c '. "$1/core/scripts/hook-lib.sh"; hq_json_get "$2"' _ "$ROOT" "hook_event_name" <<'EOF'
{"hook_event_name":"from-stdin"}
EOF
)"
[ "$STUB_VALUE" = "from-stdin" ] \
  || fail "harness hq_json_get must read stdin, not STDIN_JSON (got: $STUB_VALUE)"
ok "harness hq_json_get reads stdin"
write_policy "$ROOT/core/policies/shape-me.md" \
  "shape-me" "always" "[SessionStart]" "hard" "SHAPE_RULE_TEXT here."
OUT="$(run_hook "$ROOT/companies/indigo" "UserPromptSubmit" "hello" HQ_POLICY_EMIT=tsv)"
# single line, five tab-separated fields, no policy-reminder markup
line_count="$(printf '%s\n' "$OUT" | grep -c . || true)"
[ "$line_count" -ge 1 ] || fail "tsv: expected at least one line, got: $OUT"
first="$(printf '%s\n' "$OUT" | head -n1)"
grep -q $'\t' <<<"$first" || fail "tsv: no tabs in line: $first"
# field count
fc="$(printf '%s' "$first" | awk -F'\t' '{print NF}')"
[ "$fc" = "5" ] || fail "tsv: expected 5 fields got $fc: $first"
grep -q '<policy-reminder>' <<<"$OUT" && fail "tsv: must not emit prose markup"
slug="$(printf '%s' "$first" | cut -f1)"
scope="$(printf '%s' "$first" | cut -f2)"
path="$(printf '%s' "$first" | cut -f3)"
enf="$(printf '%s' "$first" | cut -f4)"
rule="$(printf '%s' "$first" | cut -f5)"
[ "$slug" = "shape-me" ] || fail "tsv slug=$slug"
[ "$scope" = "core" ] || fail "tsv scope=$scope"
[ -n "$path" ] || fail "tsv path empty"
[ "$enf" = "hard" ] || fail "tsv enf=$enf (expected hard)"
grep -q "SHAPE_RULE_TEXT" <<<"$rule" || fail "tsv rule missing text"
ok "tsv five-field line shape"

# ── Case 2: enforcement hard vs unset ────────────────────────────────────────
write_policy "$ROOT/core/policies/no-enf.md" \
  "no-enf" "always" "[SessionStart]" "" "NO_ENF_RULE"
OUT2="$(run_hook "$ROOT/companies/indigo" "UserPromptSubmit" "hello" HQ_POLICY_EMIT=tsv)"
grep -Eq $'^shape-me\t.*\thard\t' <<<"$OUT2" \
  || fail "hard enforcement not emitted: $OUT2"
grep -Eq $'^no-enf\t.*\tunset\t' <<<"$OUT2" \
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
grep -Eq $'^collide-me\tcompany\t.*COMPANY_COPY_MARKER' <<<"$OUT4" \
  || fail "company copy did not win: $OUT4"
grep -q CORE_COPY_MARKER <<<"$OUT4" && fail "core copy leaked: $OUT4"
ok "company wins colliding id in tsv"

# ── Case 5: HQ_POLICY_COMPANY override with CWD outside companies/ ───────────
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/companies/indigo/policies/co-only.md" \
  "co-only" "always" "[SessionStart]" "soft" "INDIGO_ONLY_MARKER"
# CWD is root (no companies/* match) but HQ_POLICY_COMPANY=indigo
OUT5="$(run_hook "$ROOT" "UserPromptSubmit" "x" HQ_POLICY_EMIT=tsv HQ_POLICY_COMPANY=indigo)"
grep -q INDIGO_ONLY_MARKER <<<"$OUT5" \
  || fail "HQ_POLICY_COMPANY override failed: $OUT5"
grep -Eq $'^co-only\tcompany\t' <<<"$OUT5" \
  || fail "scope not company: $OUT5"
ok "HQ_POLICY_COMPANY override outside companies/"

# ── Case 6: injects company policy from session meta when cwd is HQ root ─────
# US-004: the core scenario — HQ-root orchestration with an active company in
# session meta. The company policy dir must be scanned even though cwd carries
# no companies/<slug> segment.
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/companies/indigo/policies/only-indigo.md" \
  "only-indigo" "always" "[SessionStart]" "soft" "INDIGO_META_MARKER"
write_meta "meta-6" "indigo"
OUT6="$(run_hook_sid "$ROOT" "UserPromptSubmit" "x" "meta-6" HQ_POLICY_EMIT=tsv)"
grep -q INDIGO_META_MARKER <<<"$OUT6" \
  || fail "session-meta at HQ root did not inject company policy: $OUT6"
grep -Eq $'^only-indigo\tcompany\t' <<<"$OUT6" \
  || fail "session-meta policy not scoped company: $OUT6"
ok "injects company policy from session meta at HQ root"

# ── Case 7: cwd inside companies/ takes precedence over session meta ─────────
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/companies/indigo/policies/only-indigo.md" \
  "only-indigo" "always" "[SessionStart]" "soft" "INDIGO_META_MARKER"
write_policy "$ROOT/companies/other/policies/only-other.md" \
  "only-other" "always" "[SessionStart]" "soft" "OTHER_CWD_MARKER"
write_meta "meta-7" "indigo"
# cwd is companies/other; session meta says indigo. cwd must win.
OUT7="$(run_hook_sid "$ROOT/companies/other" "UserPromptSubmit" "x" "meta-7" HQ_POLICY_EMIT=tsv)"
grep -q OTHER_CWD_MARKER <<<"$OUT7" \
  || fail "cwd company policy not injected: $OUT7"
grep -q INDIGO_META_MARKER <<<"$OUT7" \
  && fail "session-meta company leaked when cwd company differs: $OUT7"
ok "cwd inside companies/ takes precedence over session meta"

# ── Case 8: HQ_POLICY_COMPANY overrides both cwd and session meta ────────────
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/companies/force/policies/only-force.md" \
  "only-force" "always" "[SessionStart]" "soft" "FORCE_ENV_MARKER"
write_policy "$ROOT/companies/other/policies/only-other.md" \
  "only-other" "always" "[SessionStart]" "soft" "OTHER_CWD_MARKER"
write_policy "$ROOT/companies/indigo/policies/only-indigo.md" \
  "only-indigo" "always" "[SessionStart]" "soft" "INDIGO_META_MARKER"
write_meta "meta-8" "indigo"
OUT8="$(run_hook_sid "$ROOT/companies/other" "UserPromptSubmit" "x" "meta-8" HQ_POLICY_EMIT=tsv HQ_POLICY_COMPANY=force)"
grep -q FORCE_ENV_MARKER <<<"$OUT8" \
  || fail "HQ_POLICY_COMPANY override not injected: $OUT8"
grep -qE 'OTHER_CWD_MARKER|INDIGO_META_MARKER' <<<"$OUT8" \
  && fail "cwd or session-meta company leaked past HQ_POLICY_COMPANY: $OUT8"
ok "HQ_POLICY_COMPANY overrides both cwd and session meta"

# ── Case 9: missing meta.yaml is a silent no-op ──────────────────────────────
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/core/policies/core-baseline.md" \
  "core-baseline" "always" "[SessionStart]" "soft" "CORE_BASELINE_MARKER"
write_policy "$ROOT/companies/indigo/policies/only-indigo.md" \
  "only-indigo" "always" "[SessionStart]" "soft" "INDIGO_META_MARKER"
# session id with NO meta.yaml on disk; cwd at HQ root.
OUT9="$(run_hook_sid "$ROOT" "UserPromptSubmit" "x" "no-such-session" HQ_POLICY_EMIT=tsv)"
grep -q INDIGO_META_MARKER <<<"$OUT9" \
  && fail "missing meta.yaml wrongly injected a company policy: $OUT9"
grep -q CORE_BASELINE_MARKER <<<"$OUT9" \
  || fail "missing meta.yaml broke core baseline (not fail-open): $OUT9"
ok "missing meta.yaml is a silent no-op"

# ── Case 10: malformed meta.yaml is a silent no-op ───────────────────────────
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/core/policies/core-baseline.md" \
  "core-baseline" "always" "[SessionStart]" "soft" "CORE_BASELINE_MARKER"
write_policy "$ROOT/companies/indigo/policies/only-indigo.md" \
  "only-indigo" "always" "[SessionStart]" "soft" "INDIGO_META_MARKER"
# meta.yaml exists but yields no usable company_slug (garbage + empty value).
write_meta_raw "meta-10" $'not: valid\ncompany_slug:\n  [broken'
OUT10="$(run_hook_sid "$ROOT" "UserPromptSubmit" "x" "meta-10" HQ_POLICY_EMIT=tsv)"
grep -q INDIGO_META_MARKER <<<"$OUT10" \
  && fail "malformed meta.yaml wrongly injected a company policy: $OUT10"
grep -q CORE_BASELINE_MARKER <<<"$OUT10" \
  || fail "malformed meta.yaml broke core baseline (not fail-open): $OUT10"
ok "malformed meta.yaml is a silent no-op"

# ── Case 11: company dir appears exactly once when cwd and meta agree ─────────
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/companies/indigo/policies/only-indigo.md" \
  "only-indigo" "always" "[SessionStart]" "soft" "INDIGO_AGREE_MARKER"
write_meta "meta-11" "indigo"
# cwd companies/indigo AND meta company_slug=indigo — same company by both paths.
OUT11="$(run_hook_sid "$ROOT/companies/indigo" "UserPromptSubmit" "x" "meta-11" HQ_POLICY_EMIT=tsv)"
n11="$(printf '%s\n' "$OUT11" | grep -c $'^only-indigo\t' || true)"
[ "$n11" = "1" ] || fail "company policy emitted $n11 times (expected exactly 1): $OUT11"
ok "company dir appears exactly once when cwd and session meta agree"

# ── Enforcement-tiered injection depth (hard = full text, soft = one-liner) ──
# write_policy_body <file> <id> <when> <on> <enforcement> — body read from stdin.
write_policy_body() {
  mkdir -p "$(dirname "$1")"
  {
    printf -- '---\nid: %s\ntitle: "%s"\nscope: test\nwhen: %s\non: %s\nenforcement: %s\n---\n\n' \
      "$2" "$2" "$3" "$4" "$5"
    cat
  } > "$1"
}

# ── Case 12: hard injects whole body, soft stays a one-liner ─────────────────
rm -rf "$ROOT"
setup_tree
write_policy_body "$ROOT/core/policies/hard-pol.md" \
  "hard-pol" "always" "[SessionStart]" "hard" <<'EOF'
## Rule

HARD_FIRST_LINE of the rule.

Second paragraph with a CRITICAL_CAVEAT that a one-line excerpt would drop.

## Rationale

HARD_RATIONALE_MARKER — why this exists.
EOF
write_policy_body "$ROOT/core/policies/soft-pol.md" \
  "soft-pol" "always" "[SessionStart]" "soft" <<'EOF'
## Rule

SOFT_FIRST_LINE of the rule.

## Rationale

SOFT_RATIONALE_MARKER — must NOT be injected.
EOF
OUT12="$(run_hook "$ROOT" "UserPromptSubmit" "x")"
grep -q 'Policy `hard-pol` (HARD — full text' <<<"$OUT12" \
  || fail "hard policy not marked as full text: $OUT12"
grep -q 'CRITICAL_CAVEAT' <<<"$OUT12" \
  || fail "hard body beyond first line not injected: $OUT12"
grep -q 'HARD_RATIONALE_MARKER' <<<"$OUT12" \
  || fail "hard Rationale section not injected: $OUT12"
# frontmatter itself is metadata, not body — must not leak into the block
grep -q 'scope: test' <<<"$OUT12" \
  && fail "frontmatter leaked into injected hard body: $OUT12"
# every injected body line stays inside the quoted reminder block
grep -q '^> .*CRITICAL_CAVEAT' <<<"$OUT12" \
  || fail "hard body line not quoted into the reminder block: $OUT12"
# soft is untouched: one-line excerpt, nothing past it
grep -q 'Policy `soft-pol` applies here: SOFT_FIRST_LINE' <<<"$OUT12" \
  || fail "soft policy lost its one-line form: $OUT12"
grep -q 'SOFT_RATIONALE_MARKER' <<<"$OUT12" \
  && fail "soft policy body was injected: $OUT12"
ok "hard injects whole body, soft stays a one-liner"

# ── Case 13: byte budget overflow falls back to summary and says so ──────────
rm -rf "$ROOT"
setup_tree
# Alphabetical filename order == MATCHES order, so aaa consumes the budget first.
write_policy_body "$ROOT/core/policies/aaa-hard.md" \
  "aaa-hard" "always" "[SessionStart]" "hard" <<'EOF'
## Rule

AAA_RULE_LINE.

AAA_BODY_MARKER padding padding padding padding padding padding padding.
EOF
write_policy_body "$ROOT/core/policies/zzz-hard.md" \
  "zzz-hard" "always" "[SessionStart]" "hard" <<'EOF'
## Rule

ZZZ_RULE_LINE.

ZZZ_BODY_MARKER padding padding padding padding padding padding padding.
EOF
# Budget fits the first body but not both.
OUT13="$(run_hook "$ROOT" "UserPromptSubmit" "x" HQ_POLICY_HARD_BUDGET_BYTES=100)"
grep -q 'AAA_BODY_MARKER' <<<"$OUT13" \
  || fail "first hard policy did not get the budget: $OUT13"
grep -q 'ZZZ_BODY_MARKER' <<<"$OUT13" \
  && fail "second hard policy exceeded the budget but was injected: $OUT13"
grep -q 'Policy `zzz-hard` applies here: ZZZ_RULE_LINE' <<<"$OUT13" \
  || fail "over-budget hard policy did not fall back to its summary: $OUT13"
# Truncation must be loud and must NAME the shortened policy.
grep -q 'Full-text budget of 100 bytes reached' <<<"$OUT13" \
  || fail "budget overflow was silent: $OUT13"
grep -q 'Full-text budget.*zzz-hard' <<<"$OUT13" \
  || fail "budget notice did not name the shortened policy: $OUT13"
ok "byte budget overflow falls back to summary and names it"

# ── Case 14: HQ_POLICY_HARD_FULL_TEXT=0 restores summary-only ────────────────
rm -rf "$ROOT"
setup_tree
write_policy_body "$ROOT/core/policies/hard-pol.md" \
  "hard-pol" "always" "[SessionStart]" "hard" <<'EOF'
## Rule

HARD_FIRST_LINE of the rule.

HARD_BODY_MARKER further down.
EOF
OUT14="$(run_hook "$ROOT" "UserPromptSubmit" "x" HQ_POLICY_HARD_FULL_TEXT=0)"
grep -q 'HARD_BODY_MARKER' <<<"$OUT14" \
  && fail "opt-out did not suppress full text: $OUT14"
grep -q 'Policy `hard-pol` applies here: HARD_FIRST_LINE' <<<"$OUT14" \
  || fail "opt-out did not fall back to the summary line: $OUT14"
ok "HQ_POLICY_HARD_FULL_TEXT=0 restores summary-only"

# ── Case 15: a nested <policy-reminder> literal cannot close the block ───────
rm -rf "$ROOT"
setup_tree
write_policy_body "$ROOT/core/policies/nested-pol.md" \
  "nested-pol" "always" "[SessionStart]" "hard" <<'EOF'
## Rule

NESTED_RULE_LINE.

This policy surfaces as a <policy-reminder> block, closed by </policy-reminder>.
EOF
OUT15="$(run_hook "$ROOT" "UserPromptSubmit" "x")"
opens="$(printf '%s\n' "$OUT15" | grep -c '<policy-reminder>' || true)"
closes="$(printf '%s\n' "$OUT15" | grep -c '</policy-reminder>' || true)"
[ "$opens" = "1" ] || fail "expected exactly 1 opening tag, got $opens: $OUT15"
[ "$closes" = "1" ] || fail "expected exactly 1 closing tag, got $closes: $OUT15"
grep -q 'NESTED_RULE_LINE' <<<"$OUT15" \
  || fail "neutralised body lost its content: $OUT15"
ok "nested policy-reminder literal cannot close the block"

# ── Case 16: hard policy with an empty body fails open to the summary form ──
# policy_body yields nothing for a file with no content after the frontmatter.
# That must degrade to the old one-line shape, not emit an empty HARD block or
# drop the policy — a malformed hard policy is the LAST thing to lose.
rm -rf "$ROOT"
setup_tree
write_policy_body "$ROOT/core/policies/empty-body.md" \
  "empty-body" "always" "[SessionStart]" "hard" </dev/null
write_policy_body "$ROOT/core/policies/normal-pol.md" \
  "normal-pol" "always" "[SessionStart]" "soft" <<'EOF'
## Rule

NORMAL_RULE_LINE.
EOF
OUT16="$(run_hook "$ROOT" "UserPromptSubmit" "x")"
grep -q 'Policy `empty-body` (HARD' <<<"$OUT16" \
  && fail "empty-bodied hard policy emitted an empty full-text block: $OUT16"
grep -q 'Policy `empty-body` applies here' <<<"$OUT16" \
  || fail "empty-bodied hard policy was dropped instead of summarised: $OUT16"
grep -q 'NORMAL_RULE_LINE' <<<"$OUT16" \
  || fail "empty-bodied hard policy broke the rest of the emit: $OUT16"
ok "empty-bodied hard policy fails open to the summary form"

# ── Case 17: reactive matches claim the cap before the baseline ──────────────
# The baseline filename sorts first, so the old scope-order head -n cap emitted
# it and dropped the policy caused by this prompt.
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/core/policies/aaa-baseline.md" "baseline-dropped" "always" "[SessionStart]" "soft" "BASELINE_DROPPED_MARKER"
write_policy "$ROOT/core/policies/zzz-reactive.md" "reactive-survives" "always" "[SessionStart, UserPromptSubmit]" "soft" "REACTIVE_SURVIVES_MARKER"
OUT17="$(run_hook "$ROOT" "UserPromptSubmit" "x" HQ_SESSION_POLICY_CAP=1)"
grep -q 'Policy `reactive-survives` applies here' <<<"$OUT17" || fail "reactive match lost the cap to baseline: $OUT17"
grep -q 'Policy `baseline-dropped` applies here' <<<"$OUT17" && fail "baseline consumed the reactive slot: $OUT17"
ok "reactive match survives cap before baseline"

# ── Case 18: stable scope precedence remains within the reactive group ──────
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/core/policies/aaa-core-reactive.md" "core-reactive" "always" "[UserPromptSubmit]" "soft" "CORE_REACTIVE_MARKER"
write_policy "$ROOT/companies/indigo/policies/zzz-company-reactive.md" "company-reactive" "always" "[UserPromptSubmit]" "soft" "COMPANY_REACTIVE_MARKER"
OUT18="$(run_hook "$ROOT/companies/indigo" "UserPromptSubmit" "x" HQ_SESSION_POLICY_CAP=1)"
grep -q 'Policy `company-reactive` applies here' <<<"$OUT18" || fail "company reactive policy did not retain scope precedence: $OUT18"
grep -q 'Policy `core-reactive` applies here' <<<"$OUT18" && fail "core reactive policy outranked company reactive policy: $OUT18"
ok "scope precedence is stable within reactive matches"

# ── Case 19: withheld policies are ledgered rather than deferred ────────────
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/core/policies/aaa-baseline.md" "withheld-baseline" "always" "[SessionStart]" "soft" "WITHHELD_BASELINE_MARKER"
write_policy "$ROOT/core/policies/zzz-reactive.md" "kept-reactive" "always" "[UserPromptSubmit]" "soft" "KEPT_REACTIVE_MARKER"
SID19="cap-ledger-$$-$RANDOM"
OUT19A="$(run_hook_sid "$ROOT" "UserPromptSubmit" "x" "$SID19" HQ_SESSION_POLICY_CAP=1)"
OUT19B="$(run_hook_sid "$ROOT" "UserPromptSubmit" "x" "$SID19" HQ_SESSION_POLICY_CAP=1)"
grep -q 'Policy `kept-reactive` applies here' <<<"$OUT19A" || fail "kept reactive policy missing from first emit: $OUT19A"
grep -Fxq 'withheld-baseline' "$ROOT/workspace/orchestrator/policy-trigger-state/$SID19.txt" || fail "withheld slug was not written to the session ledger"
grep -q 'Policy `' <<<"$OUT19B" && fail "withheld policy resurfaced on the next event: $OUT19B"
ok "withheld policies are deduped in the session ledger"

# ── Case 20: truncation notice names up to ten withheld slugs ───────────────
rm -rf "$ROOT"
setup_tree
write_policy "$ROOT/core/policies/aaa-reactive.md" "notice-reactive" "always" "[UserPromptSubmit]" "soft" "NOTICE_REACTIVE_MARKER"
i=1
while [ "$i" -le 12 ]; do
  n="$(printf '%02d' "$i")"
  write_policy "$ROOT/core/policies/cap-baseline-$n.md" "cap-baseline-$n" "always" "[SessionStart]" "soft" "CAP_BASELINE_$n"
  i=$((i + 1))
done
OUT20="$(run_hook "$ROOT" "UserPromptSubmit" "x" HQ_SESSION_POLICY_CAP=1)"
NOTICE20="$(printf '%s\n' "$OUT20" | grep '^> Session policy cap withheld ')"
grep -q 'cap-baseline-01' <<<"$NOTICE20" || fail "cap notice did not name withheld slugs: $OUT20"
grep -q 'cap-baseline-10' <<<"$NOTICE20" || fail "cap notice did not include its tenth withheld slug: $OUT20"
grep -q 'cap-baseline-11' <<<"$NOTICE20" && fail "cap notice named more than ten withheld slugs: $OUT20"
grep -Fq '(+2 more)' <<<"$NOTICE20" || fail "cap notice did not summarize remaining withheld slugs: $OUT20"
# This is the exact shape core/scripts/tests/inject-policy-e2e.test.sh's
# slugs() parser recognises. The notice must not masquerade as an injection.
case "$NOTICE20" in
  '> Policy `'*) fail "cap notice is parseable as an injected policy: $NOTICE20" ;;
esac
ok "cap notice names ten withheld slugs without mimicking a policy line"

# ── Case 21: reactive hard policy gets full-text budget before baseline ──────
rm -rf "$ROOT"
setup_tree
write_policy_body "$ROOT/core/policies/aaa-baseline-hard.md" "baseline-hard" "always" "[SessionStart]" "hard" <<'EOF'
## Rule

BASELINE_HARD_RULE.

BASELINE_HARD_BODY_MARKER.
EOF
write_policy_body "$ROOT/core/policies/zzz-reactive-hard.md" "reactive-hard" "always" "[SessionStart, UserPromptSubmit]" "hard" <<'EOF'
## Rule

REACTIVE_HARD_RULE.

REACTIVE_HARD_BODY_MARKER.
EOF
OUT21="$(run_hook "$ROOT" "UserPromptSubmit" "x" HQ_SESSION_POLICY_CAP=1 HQ_POLICY_HARD_BUDGET_BYTES=100)"
grep -q 'REACTIVE_HARD_BODY_MARKER' <<<"$OUT21" || fail "reactive hard policy did not claim full-text budget first: $OUT21"
grep -q 'BASELINE_HARD_BODY_MARKER' <<<"$OUT21" && fail "baseline hard policy consumed the reactive budget: $OUT21"
ok "reactive hard policy receives full-text budget before baseline"

echo
echo "PASS ($pass assertions)"
