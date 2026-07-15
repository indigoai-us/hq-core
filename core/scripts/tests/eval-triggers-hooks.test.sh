#!/usr/bin/env bash
# hq-core: public
# Integration tests for .claude/hooks/inject-policy-on-trigger.sh after the
# frontmatter `when:`/`on:` upgrade.
#
# Contract:
#   <hook-json on stdin> | bash inject-policy-on-trigger.sh
#     - event comes from `hook_event_name` in the JSON (default PreToolUse)
#     - resolves policy scope + dedupe ledger from $CLAUDE_PROJECT_DIR
#     - resolves helper scripts (eval-trigger.sh / derive-trigger-facts.sh)
#       relative to its OWN location (real repo), so tests can point data at a
#       temp HQ while exercising real code
#     - frontmatter path: for each in-scope policy whose `on:` includes the
#       event and whose `when:` evaluates TRUE, emits a <policy-reminder> line
#       naming the policy id; records it in
#       workspace/orchestrator/policy-trigger-state/<session_id>.txt (dedupe)
#     - legacy regex map still fires for precise PreToolUse patterns
#     - policies with no `when:` are never injected via the frontmatter path

set -euo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/.claude/hooks/inject-policy-on-trigger.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$HOOK" ] || fail "inject-policy-on-trigger.sh not found at $HOOK"

mkdir -p "$TMP/core/policies" "$TMP/workspace/orchestrator/policy-trigger-state"
LEDGER="$TMP/workspace/orchestrator/policy-trigger-state/sess-1.txt"

# A frontmatter-driven demo policy (deploy intent — matches NO legacy regex row
# so this test isolates the frontmatter path).
cat > "$TMP/core/policies/demo-deploy-rule.md" <<'EOF'
---
id: demo-deploy-rule
enforcement: soft
trigger: when deploying or sharing
when: deploy
on: [PreToolUse, UserPromptSubmit]
---

## Rule
Use /deploy for HQ artifact sharing rather than ad-hoc hosting.
EOF

# A policy with no when: — must never be injected by the frontmatter path.
cat > "$TMP/core/policies/demo-no-when.md" <<'EOF'
---
id: demo-no-when
enforcement: soft
trigger: prose only
---

## Rule
This must never be injected by the trigger hook.
EOF

call() { printf '%s' "$1" | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>/dev/null || true; }

DEPLOY_PRE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"vercel deploy --prod"},"session_id":"sess-1"}'

# 1. Matching deploy command injects the frontmatter policy.
out="$(call "$DEPLOY_PRE")"
echo "$out" | grep -q "demo-deploy-rule" || fail "expected demo-deploy-rule injected, got: [$out]"

# 2. no-when policy never injected.
echo "$out" | grep -q "demo-no-when" && fail "no-when policy must not be injected" || true

# 3. Dedupe ledger records the slug.
[ -f "$LEDGER" ] && grep -qxF "demo-deploy-rule" "$LEDGER" || fail "slug not recorded in ledger"

# 4. Second identical call -> deduped.
out2="$(call "$DEPLOY_PRE")"
echo "$out2" | grep -q "demo-deploy-rule" && fail "policy re-injected despite dedupe" || true

# 5. Unrelated command -> no injection.
out3="$(call '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"},"session_id":"sess-1"}')"
echo "$out3" | grep -q "demo-deploy-rule" && fail "policy injected for unrelated command" || true

# 6. UserPromptSubmit event with deploy intent in the prompt also injects
#    (fresh session id to avoid dedupe carryover).
out4="$(call '{"hook_event_name":"UserPromptSubmit","prompt":"please deploy this to prod","session_id":"sess-2"}')"
echo "$out4" | grep -q "demo-deploy-rule" || fail "expected injection on UserPromptSubmit deploy intent, got: [$out4]"

# 7. Legacy regex map still fires (regression guard): pgrep -> hq-bash-discipline.
out5="$(call '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"pgrep -f node"},"session_id":"sess-3"}')"
echo "$out5" | grep -q "hq-bash-discipline" || fail "legacy regex map regressed (pgrep), got: [$out5]"

# 8. Tool events are CLI/Bash-only: a non-Bash PreToolUse (Glob) injects nothing,
#    even if a deploy-ish token might otherwise appear.
out6="$(call '{"hook_event_name":"PreToolUse","tool_name":"Glob","tool_input":{"pattern":"deploy/**"},"session_id":"sess-4"}')"
[ -z "$out6" ] || fail "non-Bash PreToolUse must not inject (CLI/bash-only), got: [$out6]"

# 9. PostToolUse on a non-Bash tool also injects nothing.
out7="$(call '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_response":{"stdout":"deploy done"},"session_id":"sess-5"}')"
[ -z "$out7" ] || fail "non-Bash PostToolUse must not inject (CLI/bash-only), got: [$out7]"

# --- AssistantIntent channel: evaluate `when:` ONLY against AI-message facts ---
cat > "$TMP/core/policies/demo-intent-rule.md" <<'EOF'
---
id: demo-intent-rule
when: git
on: [AssistantIntent]
---

## Rule
Fires when the AI said it would do git work.
EOF
cat > "$TMP/core/policies/demo-git-pre.md" <<'EOF'
---
id: demo-git-pre
when: git
on: [PreToolUse]
---

## Rule
Fires when the command itself involves git.
EOF

# 10. Command has NO git, but the assistant said it would push -> the
#     AssistantIntent rule fires; the PreToolUse(command) rule does not.
TI="$TMP/ti.jsonl"
{ printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"let me git push the branch"}]}}'; } > "$TI"
outA="$(call "$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"},"transcript_path":"%s","session_id":"sessA"}' "$TI")")"
echo "$outA" | grep -q "demo-intent-rule" || fail "AssistantIntent should fire from AI message, got: [$outA]"
echo "$outA" | grep -q "demo-git-pre" && fail "PreToolUse(command) git rule must not fire on 'ls'" || true

# 11. Command HAS git, but the assistant did NOT mention it -> the
#     PreToolUse(command) rule fires; the AssistantIntent rule does not.
TI2="$TMP/ti2.jsonl"
{ printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"just looking at the files"}]}}'; } > "$TI2"
outB="$(call "$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"transcript_path":"%s","session_id":"sessB"}' "$TI2")")"
echo "$outB" | grep -q "demo-git-pre" || fail "PreToolUse(command) git rule should fire on 'git status', got: [$outB]"
echo "$outB" | grep -q "demo-intent-rule" && fail "AssistantIntent rule must NOT fire from a command token, got: [$outB]" || true

# --- SessionStart channel: ALL on:[SessionStart] policies inject unconditionally ---
# The pre-built digest was retired; this hook is the sole policy-surfacing path,
# so every on:[SessionStart] policy whose when: matches is injected — there is no
# digest to dedup against. Both a soft and a hard SessionStart policy surface.
cat > "$TMP/core/policies/demo-soft-start.md" <<'EOF'
---
id: demo-soft-start
enforcement: soft
when: always
on: [SessionStart]
---

## Rule
Soft policy introduced at session start.
EOF
cat > "$TMP/core/policies/demo-hard-start.md" <<'EOF'
---
id: demo-hard-start
enforcement: hard
when: always
on: [SessionStart]
---

## Rule
Hard policy introduced at session start.
EOF

outS="$(call '{"hook_event_name":"SessionStart","session_id":"sessS"}')"
echo "$outS" | grep -q "demo-soft-start" || fail "SessionStart should inject soft on:[SessionStart] policy, got: [$outS]"
echo "$outS" | grep -q "demo-hard-start" || fail "SessionStart should inject hard on:[SessionStart] policy unconditionally (no digest dedup), got: [$outS]"

# 12. REGRESSION — multi-line dedupe ledger must not abort the frontmatter awk.
#     After SessionStart seeds the ledger with MULTIPLE slugs (one per line), a
#     later reactive PreToolUse in the SAME session must still evaluate the
#     frontmatter path. The ledger was once passed via `awk -v ALREADY=`, which
#     onetrueawk/mawk (default awk on macOS/BSD) abort on with "newline in
#     string" whenever the value spans >1 line — silently killing ALL reactive
#     when:/on: injection for the rest of the session. It now rides ENVIRON.
#     Guard both halves: awk emits no error AND the reactive policy still fires.
LEDGER_S="$TMP/workspace/orchestrator/policy-trigger-state/sessS.txt"
[ "$(grep -c . "$LEDGER_S")" -ge 2 ] || fail "precondition: SessionStart should seed >=2 ledger slugs, got: [$(cat "$LEDGER_S" 2>/dev/null)]"
ERRF="$TMP/awk-err.txt"
out8b="$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"session_id":"sessS"}' | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>"$ERRF" || true)"
grep -q 'newline in string' "$ERRF" && fail "awk aborted on multi-line ledger (regressed to -v ALREADY): [$(cat "$ERRF")]" || true
echo "$out8b" | grep -q "demo-git-pre" || fail "reactive when:/on: must still fire after a multi-slug SessionStart ledger, got: [$out8b]"
echo "$out8b" | grep -q "demo-soft-start" && fail "SessionStart slug re-injected — ledger not honored, got: [$out8b]" || true

# 13. REGRESSION — byte-oriented awk must not split a UTF-8 code point when
#     truncating the rule summary. Byte 157 is the first byte of the em dash.
ASCII_156="$(printf '%156s' '')"
ASCII_156="${ASCII_156// /a}"
{
  cat <<'EOF'
---
id: demo-utf8-boundary
when: deploy
on: [PreToolUse]
---

## Rule
EOF
  printf '%s—suffix\n' "$ASCII_156"
} > "$TMP/core/policies/demo-utf8-boundary.md"

out_utf8="$(printf '%s' "$DEPLOY_PRE" | LC_ALL=C CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>/dev/null || true)"
printf '%s' "$out_utf8" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null \
  || fail "policy reminder is not valid UTF-8 under byte-oriented awk"
expected_utf8="> Policy \`demo-utf8-boundary\` applies here: ${ASCII_156}..."
[[ "$out_utf8" == *"$expected_utf8"* ]] \
  || fail "UTF-8 boundary rule lost its slug or truncated rule suffix, got: [$out_utf8]"

echo "PASS: inject-policy-on-trigger (frontmatter + legacy + AssistantIntent + SessionStart)"
