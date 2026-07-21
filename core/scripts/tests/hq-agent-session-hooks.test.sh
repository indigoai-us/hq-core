#!/usr/bin/env bash
# hq-core: public
# US-402 / US-404: session bootstrap, hook firing, block provenance

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

FIXTURE="$TMP/hq"
mkdir -p "$FIXTURE/core/schemas" "$FIXTURE/core/scripts" \
  "$FIXTURE/core/knowledge/public/hq-core" \
  "$FIXTURE/workspace/sessions" "$FIXTURE/.claude/hooks" \
  "$FIXTURE/companies/indigo/settings" \
  "$FIXTURE/companies/indigo/hooks/SessionStart" \
  "$FIXTURE/companies/indigo/hooks/UserPromptSubmit" \
  "$FIXTURE/core/hooks/SessionStart" \
  "$FIXTURE/core/hooks/UserPromptSubmit"
cp "$SRC_ROOT/core/core.yaml" "$FIXTURE/core/core.yaml"
cp "$SRC_ROOT/core/schemas/"*.json "$FIXTURE/core/schemas/"
cp "$SRC_ROOT/core/scripts/hq-agent-session.sh" "$FIXTURE/core/scripts/"
cp -R "$SRC_ROOT/core/scripts/lib" "$FIXTURE/core/scripts/lib"
cp "$SRC_ROOT/core/scripts/hq-session.sh" "$FIXTURE/core/scripts/"
cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/"
cp "$SRC_ROOT/core/knowledge/public/hq-core/channel-writing-formats.md" \
  "$FIXTURE/core/knowledge/public/hq-core/" 2>/dev/null || true
printf '# AGENTS\n' > "$FIXTURE/AGENTS.md"
printf '# co\n' > "$FIXTURE/companies/indigo/CLAUDE.md"
chmod +x "$FIXTURE/core/scripts/"*.sh "$FIXTURE/core/scripts/lib/"*.sh \
  "$FIXTURE/.claude/hooks/master-hook.sh"

# Company hook counters
cat > "$FIXTURE/companies/indigo/hooks/SessionStart/10-count.sh" <<'EOF'
#!/usr/bin/env bash
echo "company-session-start" >> "${HQ_HOOK_LOG:-/dev/null}"
exit 0
EOF
cat > "$FIXTURE/companies/indigo/hooks/UserPromptSubmit/10-count.sh" <<'EOF'
#!/usr/bin/env bash
echo "company-user-prompt" >> "${HQ_HOOK_LOG:-/dev/null}"
# echo prompt field presence
prompt="$(cat | jq -r '.prompt // empty')"
echo "prompt=$prompt" >> "${HQ_HOOK_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$FIXTURE/companies/indigo/hooks/SessionStart/"*.sh \
  "$FIXTURE/companies/indigo/hooks/UserPromptSubmit/"*.sh

export HOME="$TMP/home"
mkdir -p "$HOME"
export HQ_AGENT_WORKDIR="$FIXTURE"
export HQ_AGENT_SESSION_SKIP_PROVIDER=1
export HQ_HOOK_LOG="$TMP/hooks.log"
: > "$HQ_HOOK_LOG"

req() {
  jq -nc --arg msg "${1:-ship the report}" '{
    contractVersion: 1,
    agentUid: "agt_test",
    companySlug: "indigo",
    channel: "slack",
    convKey: "agt_test#slack:C1",
    messageText: $msg,
    provider: "claude",
    sender: {verified: true}
  }'
}

# ── 1. bootstrap meta + .current + hq-session get company ───────────────────
OUT="$(req | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/e1")" || fail "run failed $(cat "$TMP/e1")"
RUN_ID="$(tr -d '[:space:]' < "$FIXTURE/workspace/sessions/.current")"
[ -n "$RUN_ID" ] || fail "missing .current"
META="$FIXTURE/workspace/sessions/$RUN_ID/meta.yaml"
[ -f "$META" ] || fail "missing meta.yaml"
grep -q "session_id: $RUN_ID" "$META" || fail "meta session_id"
grep -q "company_slug: indigo" "$META" || fail "meta company_slug"
GOT="$(cd "$FIXTURE" && bash "$FIXTURE/core/scripts/hq-session.sh" get company)"
[ "$GOT" = "indigo" ] || fail "hq-session get company got '$GOT'"
pass "session bootstrap"

# ── 2. company hooks fired exactly once each ────────────────────────────────
SS_COUNT="$(grep -c 'company-session-start' "$HQ_HOOK_LOG" || true)"
UP_COUNT="$(grep -c 'company-user-prompt' "$HQ_HOOK_LOG" || true)"
[ "$SS_COUNT" -eq 1 ] || fail "SessionStart company hook count=$SS_COUNT"
[ "$UP_COUNT" -eq 1 ] || fail "UserPromptSubmit company hook count=$UP_COUNT"
grep -q 'prompt=ship the report' "$HQ_HOOK_LOG" || fail "UserPromptSubmit prompt field"
pass "company hooks once each"

# ── 3. block short-circuit with provenance ──────────────────────────────────
cat > "$FIXTURE/companies/indigo/hooks/UserPromptSubmit/00-block.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"decision":"block","reason":"test-block"}'
exit 0
EOF
chmod +x "$FIXTURE/companies/indigo/hooks/UserPromptSubmit/00-block.sh"
: > "$HQ_HOOK_LOG"
RC=0
OUT="$(req | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/e2")" || RC=$?
# blocked turn exits 0 with no_reply
[ "$RC" -eq 0 ] || fail "block should exit 0 got $RC"
echo "$OUT" | jq -e '.disposition == "no_reply"' >/dev/null || fail "block disposition: $OUT"
BLOCKED="$(echo "$OUT" | jq -r '.blockedBy // empty')"
[ -n "$BLOCKED" ] || fail "blockedBy empty: $OUT"
echo "$BLOCKED" | grep -q '00-block.sh' || fail "blockedBy should name 00-block.sh: $BLOCKED"
pass "block provenance"

# ── 4. master-hook stamps hqSessionBlockedBy with two blockers ──────────────
cat > "$FIXTURE/companies/indigo/hooks/UserPromptSubmit/01-block-b.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"decision":"block","reason":"second"}'
exit 0
EOF
chmod +x "$FIXTURE/companies/indigo/hooks/UserPromptSubmit/01-block-b.sh"
# Invoke master-hook directly
PAYLOAD="$(jq -nc --arg sid "sid-test" --arg cwd "$FIXTURE" \
  '{session_id:$sid,cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:"x"}')"
# Bootstrap meta for company hooks
mkdir -p "$FIXTURE/workspace/sessions/sid-test"
printf 'session_id: sid-test\ncompany_slug: indigo\ncompany: indigo\n' \
  > "$FIXTURE/workspace/sessions/sid-test/meta.yaml"
printf 'sid-test\n' > "$FIXTURE/workspace/sessions/.current"
HOUT="$(printf '%s' "$PAYLOAD" | bash "$FIXTURE/.claude/hooks/master-hook.sh" UserPromptSubmit)"
echo "$HOUT" | jq -e '.decision == "block"' >/dev/null || fail "merged block: $HOUT"
SRC="$(echo "$HOUT" | jq -r '.hookSpecificOutput.hqSessionBlockedBy')"
echo "$SRC" | grep -q '00-block.sh' || fail "first block should win: $SRC"
pass "two-block first wins with provenance"

# ── 5. non-zero non-block does not abort ────────────────────────────────────
rm -f "$FIXTURE/companies/indigo/hooks/UserPromptSubmit/00-block.sh" \
  "$FIXTURE/companies/indigo/hooks/UserPromptSubmit/01-block-b.sh"
cat > "$FIXTURE/companies/indigo/hooks/UserPromptSubmit/00-fail.sh" <<'EOF'
#!/usr/bin/env bash
echo "hook failed softly" >&2
exit 1
EOF
chmod +x "$FIXTURE/companies/indigo/hooks/UserPromptSubmit/00-fail.sh"
: > "$HQ_HOOK_LOG"
RC=0
OUT="$(req | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/e3")" || RC=$?
[ "$RC" -eq 0 ] || fail "non-block failure should not abort exit=$RC err=$(cat "$TMP/e3")"
echo "$OUT" | jq -e '.disposition == "reply"' >/dev/null || fail "should complete: $OUT"
pass "non-zero non-block continues"

# ── 6. updatedInput replaces user.txt ───────────────────────────────────────
cat > "$FIXTURE/companies/indigo/hooks/UserPromptSubmit/05-update.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"hookSpecificOutput":{"updatedInput":"REPLACED_USER_TEXT"}}'
exit 0
EOF
chmod +x "$FIXTURE/companies/indigo/hooks/UserPromptSubmit/05-update.sh"
RC=0
OUT="$(req | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/e4")" || RC=$?
[ "$RC" -eq 0 ] || fail "updatedInput run exit $RC"
RD="$(echo "$OUT" | jq -r .runDir)"
grep -q 'REPLACED_USER_TEXT' "$RD/user.txt" || fail "user.txt not updated: $(cat "$RD/user.txt")"
pass "updatedInput replaces user.txt"

echo "PASS: hq-agent-session-hooks.test.sh"
