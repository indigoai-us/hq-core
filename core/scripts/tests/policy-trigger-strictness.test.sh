#!/usr/bin/env bash
# hq-core: public
# Regression coverage for the policy-trigger strictness fixes:
#   1. a `when:` with a bare gap between identifiers is MALFORMED, not a
#      silently-truncated prefix expression
#   2. whitespace around every operand parses (the trailing-garbage check must
#      not reject well-formed expressions)
#   3. a malformed `when:` no longer matches every event — soft/unset is not
#      injected at all, hard degrades to a once-per-session baseline and is
#      named as malformed
#   4. a hard policy body is trimmed at the first archival heading and capped
#      per policy
#   5. validate-policy-frontmatter blocks an unconditional hard trigger on a
#      reactive event, and an over-long hard body
#   6. lint-policy-triggers finds all of the above across a tree
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EVAL="$HQ_SRC/core/scripts/eval-trigger.sh"
LINT="$HQ_SRC/core/scripts/lint-policy-triggers.sh"
INJECT="$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh"
VALIDATE="$HQ_SRC/.claude/hooks/validate-policy-frontmatter.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass+1)); printf '  ok %s\n' "$1"; }

command -v jq >/dev/null || fail "jq required"
for f in "$EVAL" "$LINT" "$INJECT" "$VALIDATE"; do [ -f "$f" ] || fail "missing $f"; done

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# ── 1 + 2: evaluator exit codes ─────────────────────────────────────────────
ev() { bash "$EVAL" "$1" "${2-}" >/dev/null 2>&1; printf '%s' "$?"; }

[ "$(ev 'merge || pull request' 'merge')" = "2" ] \
  || fail "bare-gap expression must be malformed (2), not a truncated 'merge || pull'"
[ "$(ev 'company skill || SKILL.md' 'company')" = "2" ] \
  || fail "two adjacent identifiers must be malformed (2)"
[ "$(ev '"gh pr checks"' 'gh')" = "2" ] || fail "quoted phrase must be malformed (2)"
[ "$(ev 'a)' 'a')" = "2" ] || fail "unbalanced paren must be malformed (2)"
ok "bare gaps, quotes and unbalanced parens are malformed, not silently truncated"

[ "$(ev 'git && push && shared_branch' 'git push shared_branch')" = "0" ] \
  || fail "spaced 3-term AND must evaluate TRUE"
[ "$(ev 'git && push && shared_branch' 'git push')" = "1" ] \
  || fail "spaced 3-term AND must evaluate FALSE when a term is absent"
[ "$(ev 'a || b || c' 'c')" = "0" ] || fail "spaced 3-term OR must evaluate TRUE"
[ "$(ev 'a || b || c' 'zz')" = "1" ] || fail "spaced 3-term OR must evaluate FALSE"
[ "$(ev 'a && ( b || c ) && d' 'a c d')" = "0" ] || fail "spaced parenthesised expr must evaluate TRUE"
[ "$(ev '! a && b' 'b')" = "0" ] || fail "spaced NOT must evaluate TRUE"
ok "whitespace around every operand still parses and evaluates"

# --check batch mode agrees with the single-expression parser
CHECK_OUT="$(printf '1\tgit && push && shared_branch\n2\tmerge || pull request\n' | bash "$EVAL" --check)"
[ "$(printf '%s\n' "$CHECK_OUT" | awk -F'\t' '$1==1{print $2}')" = "ok" ] \
  || fail "--check disagrees with the single-expression parser on a valid expr"
[ "$(printf '%s\n' "$CHECK_OUT" | awk -F'\t' '$1==2{print $2}')" = "malformed" ] \
  || fail "--check disagrees with the single-expression parser on a bare gap"
ok "--check batch mode agrees with the single-expression parser"

# ── injector harness ────────────────────────────────────────────────────────
setup_tree() {
  ROOT="$TMPROOT/inject-$1"
  rm -rf "$ROOT"
  mkdir -p "$ROOT/core/policies" "$ROOT/core/scripts" "$ROOT/.claude/hooks" \
    "$ROOT/workspace/orchestrator/policy-trigger-state"
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
  # Real evaluator + a fact stub, so `when:` is genuinely parsed.
  cp "$EVAL" "$ROOT/core/scripts/eval-trigger.sh"
  printf '#!/bin/bash\necho "always deploy"\n' > "$ROOT/core/scripts/derive-trigger-facts.sh"
  chmod +x "$ROOT/core/scripts/"*.sh
  cp "$INJECT" "$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
}

write_policy() {
  # write_policy <root> <slug> <when> <on> <enforcement> — body on stdin
  mkdir -p "$1/core/policies"
  {
    printf -- '---\nid: %s\ntitle: "%s"\nscope: test\nwhen: %s\non: %s\nenforcement: %s\n---\n\n' \
      "$2" "$2" "$3" "$4" "$5"
    cat
  } > "$1/core/policies/$2.md"
}

run_hook() {
  # run_hook <root> <event> [env...]
  local root="$1" event="$2"; shift 2 || true
  local input
  input="$(jq -cn --arg sid "strict-$$-$RANDOM" --arg cwd "$root" --arg e "$event" \
    '{session_id:$sid,hook_event_name:$e,cwd:$cwd,prompt:"anything"}')"
  env HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" "$@" \
    bash "$root/.claude/hooks/inject-policy-on-trigger.sh" <<<"$input" 2>/dev/null || true
}

# ── 3: a malformed `when:` no longer matches every event ────────────────────
setup_tree malformed
write_policy "$ROOT" "soft-broken" "review || pull request" "[UserPromptSubmit]" "soft" <<'EOF'
## Rule

SOFT_BROKEN_MARKER must not be injected — its trigger does not parse.
EOF
write_policy "$ROOT" "hard-broken" "review || pull request" "[UserPromptSubmit]" "hard" <<'EOF'
## Rule

HARD_BROKEN_MARKER is a binding rule whose trigger does not parse.
EOF
OUT="$(run_hook "$ROOT" UserPromptSubmit)"
grep -q 'SOFT_BROKEN_MARKER' <<<"$OUT" \
  && fail "soft policy with a malformed when: was injected (blanket fail-open): $OUT"
ok "malformed when: on a soft policy is not injected"

grep -q 'HARD_BROKEN_MARKER' <<<"$OUT" \
  || fail "hard policy with a malformed when: must still surface: $OUT"
grep -q 'Malformed `when:` trigger' <<<"$OUT" \
  || fail "malformed hard policy must be named as malformed, not passed off as a match: $OUT"
grep -q 'hard-broken' <<<"$OUT" || fail "malformed notice must name the slug: $OUT"
ok "malformed when: on a hard policy surfaces once and is reported as malformed"

# A well-formed trigger that does NOT match must stay silent — proving the
# above is about parseability, not about hard policies always firing.
setup_tree nomatch
write_policy "$ROOT" "no-match" "kubernetes" "[UserPromptSubmit]" "hard" <<'EOF'
## Rule

NO_MATCH_MARKER should never appear: `kubernetes` is not in the fact set.
EOF
OUT="$(run_hook "$ROOT" UserPromptSubmit)"
grep -q 'NO_MATCH_MARKER' <<<"$OUT" \
  && fail "a hard policy whose valid trigger is FALSE must not be injected: $OUT"
ok "a valid but non-matching hard trigger stays silent"

# ── 4: hard body trimmed at archival headings, and capped per policy ────────
setup_tree trim
write_policy "$ROOT" "trim-me" "deploy" "[UserPromptSubmit]" "hard" <<'EOF'
## Rule

BINDING_TEXT_MARKER — this must reach the session.

## Rationale

ARCHIVAL_TEXT_MARKER — history, not rule; must be trimmed.
EOF
OUT="$(run_hook "$ROOT" UserPromptSubmit)"
grep -q 'BINDING_TEXT_MARKER' <<<"$OUT" || fail "binding rule text was not injected: $OUT"
grep -q 'ARCHIVAL_TEXT_MARKER' <<<"$OUT" && fail "archival section was injected: $OUT"
ok "hard body stops at the first archival heading"

setup_tree cap
{
  printf '## Rule\n\nSUMMARY_LINE_MARKER — the one line that survives.\n\nCAPPED_BODY_MARKER is further down the body.\n\n'
  i=0; while [ "$i" -lt 300 ]; do printf 'filler line %s to push this policy over the per-policy cap.\n' "$i"; i=$((i+1)); done
} > "$TMPROOT/big-body.txt"
write_policy "$ROOT" "too-big" "deploy" "[UserPromptSubmit]" "hard" < "$TMPROOT/big-body.txt"
OUT="$(run_hook "$ROOT" UserPromptSubmit HQ_POLICY_HARD_MAX_BYTES=2048)"
grep -q 'SUMMARY_LINE_MARKER' <<<"$OUT" \
  || fail "an over-cap policy must still surface its summary line: $OUT"
grep -q 'CAPPED_BODY_MARKER' <<<"$OUT" \
  && fail "a body over the per-policy cap must fall back to the summary line only: $OUT"
grep -q 'per-policy limit' <<<"$OUT" \
  || fail "an over-cap policy must be named, never silently shortened: $OUT"
grep -q 'too-big' <<<"$OUT" || fail "over-cap notice must name the slug: $OUT"
ok "an oversized hard body falls back to its summary and is reported"

# ── 5: authoring-time enforcement ───────────────────────────────────────────
validate() {
  # validate <abs-path> <content> → prints exit code
  local p="$1" c="$2" rc=0
  printf '%s' "$c" > "$p"
  jq -cn --arg fp "$p" --arg body "$c" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$body}}' \
    | env CLAUDE_PROJECT_DIR="$TMPROOT" "${VENV[@]}" bash "$VALIDATE" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
mkdir -p "$TMPROOT/policies"
VENV=(HQ_POLICY_HARD_RULE_MAX_BYTES=400)

GOOD='---
id: good
when: deploy || publish
on: [PreToolUse]
enforcement: hard
---

## Rule

Short and specific.
'
[ "$(validate "$TMPROOT/policies/good.md" "$GOOD")" = "0" ] \
  || fail "a well-formed hard policy must be allowed"
ok "a well-formed hard policy is allowed"

LOOSE='---
id: loose
when: always
on: [PreToolUse, UserPromptSubmit]
enforcement: hard
---

## Rule

Fires on literally every command.
'
[ "$(validate "$TMPROOT/policies/loose.md" "$LOOSE")" = "2" ] \
  || fail "hard + when: always on a reactive event must be blocked"
ok "hard + unconditional when: on a reactive event is blocked at authoring time"

SS_OK='---
id: ss-ok
when: always
on: [SessionStart]
enforcement: hard
---

## Rule

Ambient governance, evaluated once per session.
'
[ "$(validate "$TMPROOT/policies/ss-ok.md" "$SS_OK")" = "0" ] \
  || fail "hard + when: always on [SessionStart] is the documented form and must be allowed"
ok "hard + unconditional when: on [SessionStart] is still allowed"

LONG="---
id: long
when: deploy
on: [PreToolUse]
enforcement: hard
---

## Rule

$(i=0; while [ "$i" -lt 40 ]; do printf 'A long binding paragraph that pushes this policy past the limit.\n'; i=$((i+1)); done)
"
[ "$(validate "$TMPROOT/policies/long.md" "$LONG")" = "2" ] \
  || fail "an over-long hard body must be blocked"
ok "an over-long hard body is blocked at authoring time"

LONG_ARCHIVED="---
id: long-archived
when: deploy
on: [PreToolUse]
enforcement: hard
---

## Rule

Short and specific.

## Rationale

$(i=0; while [ "$i" -lt 40 ]; do printf 'Long-form reasoning that is NOT injected and must not count.\n'; i=$((i+1)); done)
"
[ "$(validate "$TMPROOT/policies/long-archived.md" "$LONG_ARCHIVED")" = "0" ] \
  || fail "long text under an archival heading is not injected, so it must not count against the cap"
ok "long-form text under an archival heading does not count against the hard cap"

# Both engines must agree — node is the default, jq/awk is the fallback used
# where node is unavailable, and a silent disagreement means one host enforces
# and another does not.
for engine in node jq; do
  VENV=(HQ_POLICY_HARD_RULE_MAX_BYTES=400 HQ_HOOK_ENGINE="$engine")
  [ "$(validate "$TMPROOT/policies/good.md" "$GOOD")" = "0" ] || fail "[$engine] good policy blocked"
  [ "$(validate "$TMPROOT/policies/loose.md" "$LOOSE")" = "2" ] || fail "[$engine] loose policy allowed"
  [ "$(validate "$TMPROOT/policies/ss-ok.md" "$SS_OK")" = "0" ] || fail "[$engine] SessionStart form blocked"
  [ "$(validate "$TMPROOT/policies/long.md" "$LONG")" = "2" ] || fail "[$engine] over-long policy allowed"
  [ "$(validate "$TMPROOT/policies/long-archived.md" "$LONG_ARCHIVED")" = "0" ] \
    || fail "[$engine] archival text counted against the cap"
done
ok "the node and jq/awk validator engines agree on every case"
VENV=(HQ_POLICY_HARD_RULE_MAX_BYTES=400)

# ── 6: the tree-wide linter ─────────────────────────────────────────────────
LROOT="$TMPROOT/lint"
mkdir -p "$LROOT/core/policies"
printf -- '---\nid: ok-pol\nwhen: deploy || publish\non: [PreToolUse]\nenforcement: hard\n---\n\n## Rule\n\nFine.\n' \
  > "$LROOT/core/policies/ok-pol.md"
printf -- '---\nid: broken-pol\nwhen: merge || pull request\non: [PreToolUse]\nenforcement: soft\n---\n\n## Rule\n\nBroken trigger.\n' \
  > "$LROOT/core/policies/broken-pol.md"
printf -- '---\nid: loose-pol\nwhen: always\non: [PreToolUse]\nenforcement: hard\n---\n\n## Rule\n\nLoose trigger.\n' \
  > "$LROOT/core/policies/loose-pol.md"

LOUT=""; LRC=0
LOUT="$(HQ_ROOT="$LROOT" bash "$LINT" 2>&1)" || LRC=$?
[ "$LRC" = "1" ] || fail "linter must exit 1 when a malformed trigger exists (got $LRC): $LOUT"
grep -q 'MALFORMED.*broken-pol' <<<"$LOUT" || fail "linter missed the malformed trigger: $LOUT"
grep -q 'LOOSE.*loose-pol' <<<"$LOUT" || fail "linter missed the loose hard trigger: $LOUT"
grep -q 'ok-pol' <<<"$LOUT" && fail "linter flagged a clean policy: $LOUT"
grep -q 'policies scanned: 3' <<<"$LOUT" || fail "linter scanned the wrong number of files: $LOUT"
ok "linter reports malformed and loose triggers and exits non-zero"

rm "$LROOT/core/policies/broken-pol.md"
LRC=0
LOUT="$(HQ_ROOT="$LROOT" bash "$LINT" 2>&1)" || LRC=$?
[ "$LRC" = "0" ] || fail "linter must exit 0 when only WARN-level findings remain: $LOUT"
LRC=0
LOUT="$(HQ_ROOT="$LROOT" bash "$LINT" --strict 2>&1)" || LRC=$?
[ "$LRC" = "1" ] || fail "--strict must exit 1 on a loose trigger: $LOUT"
ok "--strict escalates LOOSE/OVERSIZE to a non-zero exit"

# ── The shipped tree must pass its own linter ───────────────────────────────
SRC_RC=0
SRC_OUT="$(HQ_ROOT="$HQ_SRC" bash "$LINT" --strict 2>&1)" || SRC_RC=$?
[ "$SRC_RC" = "0" ] || fail "this repo's own policies do not pass the linter:
$SRC_OUT"
ok "the shipped core/policies tree passes the linter in --strict mode"

printf '\nPASS (%s assertions)\n' "$pass"
