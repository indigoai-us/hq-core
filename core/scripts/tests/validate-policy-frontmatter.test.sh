#!/usr/bin/env bash
# Regression: validate-policy-frontmatter.sh (PreToolUse Write/Edit/MultiEdit)
# blocks creating/editing a policy file whose RESULTING frontmatter lacks when:
# or on:, or whose when: expression is outside the documented boolean grammar,
# and leaves everything else alone. Also verifies the hook is live under all
# three hook-gate profiles (per hq-hook-gate-three-profile-lists).
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HQ_TEST_ROOT:-$(cd "$TEST_DIR/../../.." && pwd)}"
HOOK="${HOOK:-$ROOT/.claude/hooks/validate-policy-frontmatter.sh}"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$HOOK" ] || fail "hook not found: $HOOK"

# The hook normally receives CLAUDE_PROJECT_DIR as its HQ root. This test uses
# a synthetic project dir to exercise path coverage, so anchor the canonical
# evaluator to this checkout instead. Clear ambient policy knobs: this test's
# expected blocks must not depend on the invoking shell.
export HQ_ROOT="${HQ_ROOT:-$ROOT}"
unset HQ_ALLOW_POLICY_NO_TRIGGER HQ_POLICY_HARD_RULE_MAX_BYTES HQ_HOOK_ENGINE || true

PROJ="$(mktemp -d)"; trap 'rm -rf "$PROJ"' EXIT
mkdir -p "$PROJ/core/policies" "$PROJ/companies/acme/policies" "$PROJ/.claude/audit/policies" "$PROJ/repos/private/x/.claude/policies"
export CLAUDE_PROJECT_DIR="$PROJ"

GOOD=$'---\nid: hq-x\nwhen: git && push\non: [PreToolUse]\nenforcement: soft\n---\n## Rule\nx\n'
GOOD_COMPLEX=$'---\nid: hq-x\nwhen: git && ( push || ! /deep-plan )\non: [PreToolUse]\nenforcement: soft\n---\n## Rule\nx\n'
NOWHENON=$'---\nid: hq-x\ntitle: X\nenforcement: soft\n---\n## Rule\nx\n'
NOON=$'---\nid: hq-x\nwhen: always\nenforcement: soft\n---\nx\n'
NOWHEN=$'---\nid: hq-x\non: [SessionStart]\nenforcement: soft\n---\nx\n'
BAD_QUOTED=$'---\nid: hq-x\nwhen: git && "push"\non: [PreToolUse]\nenforcement: soft\n---\nx\n'
BAD_ADJACENT=$'---\nid: hq-x\nwhen: git push\non: [PreToolUse]\nenforcement: soft\n---\nx\n'
BAD_DANGLING=$'---\nid: hq-x\nwhen: git &&\non: [PreToolUse]\nenforcement: soft\n---\nx\n'
BAD_PARENS=$'---\nid: hq-x\nwhen: git && (push || commit\non: [PreToolUse]\nenforcement: soft\n---\nx\n'
BAD_PUNCT=$'---\nid: hq-x\nwhen: git & push\non: [PreToolUse]\nenforcement: soft\n---\nx\n'
BAD_LEADING_DASH=$'---\nid: hq-x\nwhen: --test || test\non: [PreToolUse]\nenforcement: soft\n---\nx\n'
BAD_COLON=$'---\nid: hq-x\nwhen: node:test\non: [PreToolUse]\nenforcement: soft\n---\nx\n'
BAD_AT=$'---\nid: hq-x\nwhen: @layer\non: [PreToolUse]\nenforcement: soft\n---\nx\n'
BAD_BLOCK=$'---\nid: hq-x\nwhen: >-\n  git || push\non: [PreToolUse]\nenforcement: soft\n---\nx\n'
BAD_PULL_REQUEST=$'---\nid: hq-x\nwhen: (pr || "pull request")\non: [PreToolUse]\nenforcement: soft\n---\nx\n'
GOOD_PULL_REQUEST=$'---\nid: hq-x\nwhen: (pr || (pull && request))\non: [PreToolUse]\nenforcement: soft\n---\nx\n'
BAD_MULTIWORD=$'---\nid: hq-x\nwhen: root cause\non: [PreToolUse]\nenforcement: soft\n---\nx\n'
GOOD_AMBIENT=$'---\nid: hq-x\nwhen: always\non: [SessionStart]\nenforcement: soft\n---\nx\n'
DUPLICATE_EMPTY_WHEN=$'---\nid: hq-x\nwhen: git && push\nwhen:\non: [PreToolUse]\nenforcement: soft\n---\nx\n'

wrc() { printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1; echo $?; }
wp() { jq -nc --arg fp "$1" --arg c "$2" '{tool_input:{file_path:$fp,content:$c}}'; }
ep() { jq -nc --arg fp "$1" --arg o "$2" --arg n "$3" '{tool_input:{file_path:$fp,old_string:$o,new_string:$n}}'; }
exp() { local want="$1" got; got="$(wrc "$2")"; [ "$got" = "$want" ] || fail "want $want got $got :: $3"; pass "$3"; }

echo "[1] Write: policy with when+on ALLOWED; missing BLOCKED"
exp 0 "$(wp "$PROJ/core/policies/ok.md"   "$GOOD")"     "core policy with when/on -> allow"
exp 2 "$(wp "$PROJ/core/policies/bad.md"  "$NOWHENON")" "core policy missing when+on -> block"
exp 2 "$(wp "$PROJ/core/policies/bad2.md" "$NOON")"     "core policy missing on -> block"
exp 2 "$(wp "$PROJ/core/policies/bad3.md" "$NOWHEN")"   "core policy missing when -> block"
exp 2 "$(wp "$PROJ/core/policies/nofm.md" "no frontmatter here")" "policy with no frontmatter -> block"

echo "[2] when: grammar is enforced identically by both analyzer engines"
for engine in node jq; do
  wrc_engine() { printf '%s' "$2" | HQ_HOOK_ENGINE="$1" bash "$HOOK" >/dev/null 2>&1; echo $?; }
  exp_engine() {
    local want="$1" engine="$2" payload="$3" label="$4" got
    got="$(wrc_engine "$engine" "$payload")"
    [ "$got" = "$want" ] || fail "$engine: want $want got $got :: $label"
    pass "$engine: $label"
  }
  exp_engine_names_expression() {
    local engine="$1" payload="$2" expression="$3" label="$4" got output
    output="$(printf '%s' "$payload" | HQ_HOOK_ENGINE="$engine" bash "$HOOK" 2>&1)" && got=0 || got=$?
    [ "$got" = "2" ] || fail "$engine: want rc 2 got $got :: $label"
    printf '%s\n' "$output" | grep -F -- "when: $expression" >/dev/null || fail "$engine: block message must name '$expression' :: $label"
    pass "$engine: $label"
  }
  exp_engine 0 "$engine" "$(wp "$PROJ/core/policies/complex.md" "$GOOD_COMPLEX")" "nested valid expression -> allow"
  exp_engine_names_expression "$engine" "$(wp "$PROJ/core/policies/pull-request.md" "$BAD_PULL_REQUEST")" '(pr || "pull request")' "quoted multiword expression -> block and name expression"
  exp_engine 0 "$engine" "$(wp "$PROJ/core/policies/pull-request-good.md" "$GOOD_PULL_REQUEST")" "explicit AND for multiword expression -> allow"
  exp_engine_names_expression "$engine" "$(wp "$PROJ/core/policies/root-cause.md" "$BAD_MULTIWORD")" 'root cause' "bare multiword expression -> block and name expression"
  exp_engine 0 "$engine" "$(wp "$PROJ/core/policies/ambient.md" "$GOOD_AMBIENT")" "always with SessionStart -> allow"
  exp_engine 2 "$engine" "$(wp "$PROJ/core/policies/quoted.md" "$BAD_QUOTED")" "quoted atom -> block"
  exp_engine 2 "$engine" "$(wp "$PROJ/core/policies/adjacent.md" "$BAD_ADJACENT")" "adjacent atoms -> block"
  exp_engine 2 "$engine" "$(wp "$PROJ/core/policies/dangling.md" "$BAD_DANGLING")" "dangling operator -> block"
  exp_engine 2 "$engine" "$(wp "$PROJ/core/policies/parens.md" "$BAD_PARENS")" "unbalanced parentheses -> block"
  exp_engine 2 "$engine" "$(wp "$PROJ/core/policies/punct.md" "$BAD_PUNCT")" "unsupported operator -> block"
  exp_engine 2 "$engine" "$(wp "$PROJ/core/policies/leading-dash.md" "$BAD_LEADING_DASH")" "leading-dash atom -> block"
  exp_engine 2 "$engine" "$(wp "$PROJ/core/policies/colon.md" "$BAD_COLON")" "colon atom -> block"
  exp_engine 2 "$engine" "$(wp "$PROJ/core/policies/at.md" "$BAD_AT")" "at-sign atom -> block"
  exp_engine 2 "$engine" "$(wp "$PROJ/core/policies/block.md" "$BAD_BLOCK")" "YAML block scalar -> block"
done

echo "[2a] every duplicate when: entry is checked, including an empty one"
for engine in node jq; do
  exp_engine 2 "$engine" "$(wp "$PROJ/core/policies/duplicate-empty-when.md" "$DUPLICATE_EMPTY_WHEN")" \
    "valid when followed by empty when -> block"
done

echo "[2b] missing canonical evaluator fails closed with its resolved path"
missing_root="$PROJ/no-evaluator-root"
output="$(printf '%s' "$(wp "$PROJ/core/policies/missing-evaluator.md" "$GOOD")" | HQ_ROOT="$missing_root" bash "$HOOK" 2>&1)" && got=0 || got=$?
[ "$got" = "2" ] || fail "missing evaluator: want rc 2 got $got"
printf '%s\n' "$output" | grep -F -- "$missing_root/core/scripts/eval-trigger.sh" >/dev/null || fail "missing evaluator message must name checked path"
printf '%s\n' "$output" | grep -F -- "blocked fail-closed" >/dev/null || fail "missing evaluator message must name fail-closed path"
pass "missing canonical evaluator -> explicit fail-closed block"

echo "[2c] a non-executable evaluator honors the operator override"
disabled_root="$PROJ/non-executable-evaluator-root"
mkdir -p "$disabled_root/core/scripts"
cp "$ROOT/core/scripts/eval-trigger.sh" "$disabled_root/core/scripts/eval-trigger.sh"
chmod -x "$disabled_root/core/scripts/eval-trigger.sh"
payload="$(wp "$PROJ/core/policies/non-executable-evaluator.md" "$GOOD")"
output="$(printf '%s' "$payload" | HQ_ROOT="$disabled_root" bash "$HOOK" 2>&1)" && got=0 || got=$?
[ "$got" = "2" ] || fail "non-executable evaluator without override: want rc 2 got $got"
printf '%s\n' "$output" | grep -F -- "$disabled_root/core/scripts/eval-trigger.sh" >/dev/null || fail "non-executable evaluator message must name checked path"
pass "non-executable evaluator without override -> block"
output="$(printf '%s' "$payload" | HQ_ROOT="$disabled_root" HQ_ALLOW_POLICY_NO_TRIGGER=1 bash "$HOOK" 2>&1)" && got=0 || got=$?
[ "$got" = "0" ] || fail "non-executable evaluator with override: want rc 0 got $got"
printf '%s\n' "$output" | grep -F -- "override active" >/dev/null || fail "override path must be noted on stderr"
pass "non-executable evaluator with override -> allow and note degraded validation"

echo "[2d] every deny message hardens the validator override"
HARD_ALWAYS_REACTIVE=$'---\nid: hq-x\nwhen: always\non: [PreToolUse]\nenforcement: hard\n---\n## Rule\nx\n'
HARD_UPPER_ALWAYS_REACTIVE=$'---\nid: hq-x\nwhen: ALWAYS\non: [UserPromptSubmit]\nenforcement: hard\n---\n## Rule\nx\n'
HARD_TOO_LONG=$'---\nid: hq-x\nwhen: deploy\non: [PreToolUse]\nenforcement: hard\n---\n## Rule\nThis binding rule is deliberately longer than one byte.\n'
assert_hardened_override_deny() {
  local label="$1" payload="$2" output got
  shift 2
  output="$(printf '%s' "$payload" | env "$@" bash "$HOOK" 2>&1)" && got=0 || got=$?
  [ "$got" = "2" ] || fail "$label: want rc 2 got $got"
  if ! printf '%s\n' "$output" | grep -F -- "explicit human permission" >/dev/null; then
    fail "$label: deny message omits explicit human permission: $output"
  fi
  if ! printf '%s\n' "$output" | grep -F -- "never set, export, or write it on its own initiative" >/dev/null; then
    fail "$label: deny message permits autonomous override: $output"
  fi
  if printf '%s\n' "$output" | grep -F -- "(Operator override: set HQ_ALLOW_POLICY_NO_TRIGGER=1" >/dev/null; then
    fail "$label: deny message still contains a bare override recipe: $output"
  fi
  pass "$label: override wording requires human permission without a bare recipe"
}
assert_hardened_override_deny "hard always/reactive" \
  "$(wp "$PROJ/core/policies/hard-always.md" "$HARD_ALWAYS_REACTIVE")"
for engine in node jq; do
  assert_hardened_override_deny "uppercase ALWAYS/reactive ($engine)" \
    "$(wp "$PROJ/core/policies/hard-upper-always.md" "$HARD_UPPER_ALWAYS_REACTIVE")" \
    "HQ_HOOK_ENGINE=$engine"
done
assert_hardened_override_deny "hard body limit" \
  "$(wp "$PROJ/core/policies/hard-long.md" "$HARD_TOO_LONG")" HQ_POLICY_HARD_RULE_MAX_BYTES=1
assert_hardened_override_deny "malformed when" \
  "$(wp "$PROJ/core/policies/bad-override-wording.md" "$BAD_QUOTED")"
assert_hardened_override_deny "missing trigger frontmatter" \
  "$(wp "$PROJ/core/policies/missing-override-wording.md" "$NOWHENON")"

echo "[3] scope coverage: company + repo policies enforced too"
exp 2 "$(wp "$PROJ/companies/acme/policies/x.md" "$NOWHENON")"     "company policy missing -> block"
exp 2 "$(wp "$PROJ/repos/private/x/.claude/policies/y.md" "$NOON")" "repo policy missing -> block"

echo "[4] exclusions: non-policy, audit store, README allowed; retired digest blocked"
exp 0 "$(wp "$PROJ/core/scripts/foo.sh" "echo hi")"                       "non-policy path -> allow"
exp 0 "$(wp "$PROJ/.claude/audit/policies/repo-internal-codes.md" "$NOWHENON")" "audit redaction rule -> allow"
exp 0 "$(wp "$PROJ/core/policies/README.md" "no frontmatter")"            "policies/README.md -> allow"
exp 2 "$(wp "$PROJ/core/policies/_digest.md" "no frontmatter")"           "retired policies/_digest.md path -> block"

echo "[5] Edit / MultiEdit reflect the RESULTING content"
POL="$PROJ/core/policies/live.md"; printf '%s' "$GOOD" > "$POL"
exp 0 "$(ep "$POL" "x" "y")"                             "edit body only -> allow"
exp 2 "$(ep "$POL" $'when: git && push\n' "")"           "edit removes when -> block"
exp 2 "$(ep "$POL" "when: git && push" "when: git push")" "edit makes when malformed -> block"
ME="$(jq -nc --arg fp "$POL" '{tool_input:{file_path:$fp,edits:[{old_string:"on: [PreToolUse]\n",new_string:""}]}}')"
exp 2 "$ME" "multiedit removes on -> block"

echo "[6] operator override allows the write"
got="$(printf '%s' "$(wp "$PROJ/core/policies/bad.md" "$NOWHENON")" | HQ_ALLOW_POLICY_NO_TRIGGER=1 bash "$HOOK" >/dev/null 2>&1; echo $?)"
[ "$got" = "0" ] || fail "override should allow, got $got"; pass "HQ_ALLOW_POLICY_NO_TRIGGER=1 -> allow"
got="$(printf '%s' "$(wp "$PROJ/core/policies/bad-when.md" "$BAD_QUOTED")" | HQ_ALLOW_POLICY_NO_TRIGGER=1 bash "$HOOK" >/dev/null 2>&1; echo $?)"
[ "$got" = "0" ] || fail "override should allow malformed when, got $got"; pass "override allows malformed when"

echo "[7] LIVE under all three hook-gate profiles (must block, rc=2)"
for p in minimal standard strict; do
  rc="$(printf '%s' "$(wp "$PROJ/core/policies/bad.md" "$NOWHENON")" | HQ_HOOK_PROFILE=$p bash "$GATE" validate-policy-frontmatter "$HOOK" >/dev/null 2>&1; echo $?)"
  [ "$rc" = "2" ] || fail "profile $p: want rc 2 got $rc (hook dead under this profile)"; pass "gate profile $p -> block"
done

echo "PASS: validate-policy-frontmatter"
