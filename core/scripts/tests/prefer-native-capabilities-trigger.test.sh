#!/usr/bin/env bash
# prefer-native-capabilities-trigger.test.sh — US-001 acceptance battery for
# core/policies/hq-prefer-native-capabilities.md.
#
# Drives the REAL hook (.claude/hooks/inject-policy-on-trigger.sh) with fresh
# session ids (a never-used session id == an empty dedupe ledger) and asserts:
#   1. The policy is REACTIVE-ONLY and stays that way: `on:` does not list
#      SessionStart and `when:` carries no `always` head, so a SessionStart
#      payload does NOT inject the slug. It was an always-injected baseline
#      until #666 narrowed it; this case pins the narrower scope so neither
#      direction can drift again silently.
#   2. A UserPromptSubmit payload containing the token 'canvas' injects the slug.
#   3. The surfaced one-liner is the untruncated first ## Rule line (< 160 chars,
#      so the hook never appends "...").
#   4. Per-session dedupe: the slug fires at most once per session.
#   5. The policy file passes .claude/hooks/validate-policy-frontmatter.sh
#      (simulated Write PreToolUse payload).
#   6. An explicitly requested local Slack file attachment may use the audited
#      native upload helper without weakening /deploy or channel authorization.
#
# Explicitly wired into .github/workflows/pr-checks.yml — tests here are NOT
# auto-discovered (indigo-hq-core-staging-pr-mechanics rule 3).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
VALIDATOR="$ROOT/.claude/hooks/validate-policy-frontmatter.sh"
POLICY="$ROOT/core/policies/hq-prefer-native-capabilities.md"
POLICY_TEXT="$(tr '\n' ' ' < "$POLICY" | tr -s '[:space:]' ' ')"
SLUG="hq-prefer-native-capabilities"
PASS=0; FAIL=0

# Unique-per-run nonce so leftover dedupe ledgers from prior runs never
# pre-suppress this run; track created ledger files and remove them on exit.
RUN="pnc-$$-$RANDOM"
LEDGER_DIR="$ROOT/workspace/orchestrator/policy-trigger-state"
trap 'rm -f "$LEDGER_DIR"/pnc-*"-$RUN"*.txt 2>/dev/null || true' EXIT

# run_hook <event> <session-suffix> <json-body-fragment> -> hook stdout
run_hook() {
  printf '{"hook_event_name":"%s","session_id":"pnc-%s-%s",%s}' "$1" "$2" "$RUN" "$3" \
    | HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" 2>/dev/null
}

ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

# extract the reminder line for our slug from hook output ("" if absent)
slug_line() { printf '%s\n' "$1" | grep -F "> Policy \`$SLUG\`" || true; }

echo "== 1. Policy is reactive-only: no SessionStart baseline =="
# The frontmatter is the contract. A policy is an always-injected baseline only
# when `on:` lists SessionStart AND `when:` reduces to TRUE via an `always`
# head; assert both are absent so a re-widening cannot slip in unnoticed.
FM="$(awk '/^---$/{d++; next} d==1' "$POLICY")"
FM_ON="$(printf '%s\n' "$FM" | grep -E '^on:' || true)"
FM_WHEN="$(printf '%s\n' "$FM" | grep -E '^when:' || true)"
if printf '%s' "$FM_ON" | grep -Fq SessionStart; then
  fail "frontmatter is reactive-only" "on: still lists SessionStart -> $FM_ON"
elif printf '%s' "$FM_WHEN" | grep -Eq '^when:[[:space:]]*always([[:space:]]*\|\||[[:space:]]*$)'; then
  fail "frontmatter is reactive-only" "when: still carries an 'always' head -> $FM_WHEN"
else
  ok "frontmatter is reactive-only (no SessionStart, no 'always' head)"
fi
# ...and the hook agrees: a SessionStart payload must not inject the slug.
O="$(run_hook SessionStart ss "$(printf '"cwd":"%s"' "$ROOT")")"
LINE="$(slug_line "$O")"
if [ -z "$LINE" ]; then ok "SessionStart does not inject $SLUG"; else
  fail "SessionStart does not inject $SLUG" "unexpected baseline injection: $LINE"
fi

echo "== 2. UserPromptSubmit containing 'canvas' injects the policy =="
O2="$(run_hook UserPromptSubmit up "$(printf '"prompt":"share this as a canvas","cwd":"%s"' "$ROOT")")"
LINE2="$(slug_line "$O2")"
if [ -n "$LINE2" ]; then ok "UserPromptSubmit 'canvas' injects $SLUG"; else
  fail "UserPromptSubmit 'canvas' injects $SLUG" "slug missing; got: $(printf '%s' "$O2" | tr '\n' ' ' | cut -c1-300)"
fi

echo "== 3. Surfaced one-liner is self-contained (untruncated, <160 chars) =="
RULE_LINE="$(awk '/^## Rule[ \t]*$/{f=1;next} f&&NF{print;exit}' "$POLICY")"
RULE_LEN="$(printf '%s' "$RULE_LINE" | awk '{print length($0)}')"
if [ -n "$RULE_LINE" ] && [ "${RULE_LEN:-999}" -lt 160 ]; then
  ok "first ## Rule line is ${RULE_LEN} chars (<160)"
else
  fail "first ## Rule line <160 chars" "len=${RULE_LEN:-unset}"
fi
# Read the line the policy actually surfaces on — the reactive path (case 2).
case "$LINE2" in
  *'...') fail "reminder untruncated" "hook truncated the one-liner: $LINE2" ;;
  '') fail "reminder untruncated" "no reminder line captured in case 2" ;;
  *) ok "reminder line is the full one-liner (no '...' truncation)" ;;
esac

echo "== 4. Per-session dedupe: slug fires at most once per session =="
# Session 'up' already matched in case 2, so a second matching prompt in that
# same session must be suppressed by the session ledger. (Session 'ss' is not
# usable here: it never fires at all now, so it could not prove dedupe.)
O3="$(run_hook UserPromptSubmit up "$(printf '"prompt":"share this as a canvas","cwd":"%s"' "$ROOT")")"
if [ -z "$(slug_line "$O3")" ]; then ok "deduped on 2nd event of same session"; else
  fail "deduped on 2nd event of same session" "slug re-fired: $(slug_line "$O3")"
fi

echo "== 5. Policy passes validate-policy-frontmatter.sh (simulated Write) =="
if command -v jq >/dev/null 2>&1; then
  VJSON="$(jq -n --arg fp "$POLICY" --rawfile c "$POLICY" \
    '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
  if printf '%s' "$VJSON" | CLAUDE_PROJECT_DIR="$ROOT" bash "$VALIDATOR" >/dev/null 2>&1; then
    ok "validate-policy-frontmatter.sh allows the policy"
  else
    fail "validate-policy-frontmatter.sh allows the policy" "validator blocked (exit != 0)"
  fi
else
  fail "validate-policy-frontmatter.sh allows the policy" "jq unavailable to build hook payload"
fi

echo "== 6. Requested Slack attachment exception preserves sharing boundaries =="
if grep -Fq "explicitly asks to attach a local file in Slack" <<< "$POLICY_TEXT" \
  && grep -Fq "native audited Slack upload helper" <<< "$POLICY_TEXT"; then
  ok "explicit local-file request permits the audited Slack upload helper"
else
  fail "explicit local-file request permits the audited Slack upload helper" \
    "expected the policy to name both explicit authorization and the native audited helper"
fi
if grep -Fq "does not authorize posting to a different or unrequested channel" <<< "$POLICY_TEXT" \
  && grep -Fq "not publishing or hosting an artifact" <<< "$POLICY_TEXT"; then
  ok "attachment exception is scoped to the authorized conversation"
else
  fail "attachment exception is scoped to the authorized conversation" \
    "expected channel authorization and attachment-vs-publishing boundaries"
fi
if grep -Fq '| Share a URL-shaped artifact (report, dashboard, deck, site) | `/deploy` |' "$POLICY"; then
  ok "URL-shaped deliverables still prefer /deploy"
else
  fail "URL-shaped deliverables still prefer /deploy" \
    "expected the HQ-native replacement table to retain the /deploy preference"
fi
if grep -Fq "do not upload artifacts as" "$POLICY"; then
  fail "blanket Slack-file prohibition removed" "policy still prohibits every Slack file upload"
else
  ok "blanket Slack-file prohibition removed"
fi

echo
echo "==== prefer-native-capabilities-trigger: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ] || exit 1
