#!/usr/bin/env bash
# hq-core: public
# US-406 / US-409: skill dispatch — resolution, skill.txt, system/user separation,
# clarify path, body truncation, contract trust classification doc.
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

FIXTURE="$TMP/hq"
mkdir -p "$FIXTURE/core/schemas" "$FIXTURE/core/scripts" \
  "$FIXTURE/core/knowledge/public/hq-core" \
  "$FIXTURE/core/policies" \
  "$FIXTURE/companies/indigo/settings" \
  "$FIXTURE/workspace/sessions" \
  "$FIXTURE/workspace/orchestrator/policy-trigger-state" \
  "$FIXTURE/.claude/hooks" \
  "$FIXTURE/.claude/skills/handoff" \
  "$FIXTURE/.claude/skills/alpha" \
  "$FIXTURE/.claude/skills/beta" \
  "$FIXTURE/.claude/skills/gamma" \
  "$FIXTURE/personal/policies"

cp "$SRC_ROOT/core/core.yaml" "$FIXTURE/core/core.yaml"
cp "$SRC_ROOT/core/schemas/"*.json "$FIXTURE/core/schemas/"
cp "$SRC_ROOT/core/scripts/hq-agent-session.sh" "$FIXTURE/core/scripts/"
cp -R "$SRC_ROOT/core/scripts/lib" "$FIXTURE/core/scripts/lib"
cp "$SRC_ROOT/core/scripts/hq-session.sh" "$FIXTURE/core/scripts/" 2>/dev/null || true
cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/" 2>/dev/null || true
cp "$SRC_ROOT/.claude/hooks/inject-policy-on-trigger.sh" "$FIXTURE/.claude/hooks/"
# Contract doc (trust classification)
mkdir -p "$FIXTURE/core/knowledge/public/hq-core"
cp "$SRC_ROOT/core/knowledge/public/hq-core/agent-session-contract.md" \
  "$FIXTURE/core/knowledge/public/hq-core/"
cat > "$FIXTURE/core/scripts/hook-lib.sh" <<'EOF'
hq_json_get() {
  printf '%s' "$STDIN_JSON" | jq -r --arg k "$1" '
    if $k == "hook_event_name" then .hook_event_name // empty
    elif $k == "session_id" then .session_id // empty
    elif $k == "tool_name" then .tool_name // empty
    elif $k == "cwd" then .cwd // empty
    else empty end'
}
EOF
printf '#!/bin/bash\necho always\n' > "$FIXTURE/core/scripts/derive-trigger-facts.sh"
printf '#!/bin/bash\nexit 0\n' > "$FIXTURE/core/scripts/eval-trigger.sh"
printf '# Formats\n\n## slack\n\nSlack.\n' \
  > "$FIXTURE/core/knowledge/public/hq-core/channel-writing-formats.md"
printf 'CHARTER\n' > "$FIXTURE/AGENTS.md"
printf 'COMPANY\n' > "$FIXTURE/companies/indigo/CLAUDE.md"

cat > "$FIXTURE/.claude/skills/handoff/SKILL.md" <<'EOF'
---
name: handoff
description: Preserve session state for a follow-up agent.
---

# Handoff

HANDOFF_BODY_SENTENCE_UNIQUE for dispatch tests.
EOF
for n in alpha beta gamma; do
  cat > "$FIXTURE/.claude/skills/$n/SKILL.md" <<EOF
---
name: $n
description: Skill $n.
---

# $n body
EOF
done

chmod +x "$FIXTURE/core/scripts/"*.sh "$FIXTURE/core/scripts/lib/"*.sh \
  "$FIXTURE/.claude/hooks/"*.sh 2>/dev/null || true

export HOME="$TMP/home"
mkdir -p "$HOME"
export HQ_AGENT_WORKDIR="$FIXTURE"
export HQ_AGENT_SESSION_SKIP_PROVIDER=1

req_for() {
  jq -nc --arg t "$1" '{
    contractVersion: 1,
    agentUid: "agt_test",
    companySlug: "indigo",
    channel: "slack",
    convKey: "agt_test#slack:C1",
    messageText: $t,
    provider: "claude",
    sender: {verified: true}
  }'
}

# ── Resolve /handoff ─────────────────────────────────────────────────────────
OUT="$(printf '%s' "$(req_for '/handoff')" | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err1")" || \
  fail "dispatch failed: $(cat "$TMP/err1")"
RUN="$(echo "$OUT" | jq -r .runDir)"
[ -f "$RUN/skill.txt" ] || fail "skill.txt missing"
grep -q 'HANDOFF_BODY_SENTENCE_UNIQUE' "$RUN/skill.txt" || fail "body missing from skill.txt"
grep -q '<!-- hq-section: skill -->' "$RUN/system.txt" || fail "skill section missing"
grep -q 'HANDOFF_BODY_SENTENCE_UNIQUE' "$RUN/system.txt" || fail "body missing from system.txt"
# user.txt must not contain the skill body sentence
if grep -q 'HANDOFF_BODY_SENTENCE_UNIQUE' "$RUN/user.txt"; then
  fail "skill body leaked into user.txt"
fi
# user.txt should still carry the slash command as channel text
grep -q '/handoff' "$RUN/user.txt" || fail "messageText missing from user.txt"
disp="$(echo "$OUT" | jq -r .disposition)"
# With SKIP_PROVIDER, disposition is reply (skill resolved, no clarify)
[ "$disp" = "reply" ] || fail "disposition=$disp want reply"
pass "resolve /handoff → skill.txt + system section, not user.txt"

# ── Unresolved /handof → clarify ─────────────────────────────────────────────
OUT2="$(printf '%s' "$(req_for '/handof')" | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err2")" || \
  fail "clarify path failed: $(cat "$TMP/err2")"
disp2="$(echo "$OUT2" | jq -r .disposition)"
[ "$disp2" = "clarify" ] || fail "disposition=$disp2 want clarify"
text2="$(echo "$OUT2" | jq -r .text)"
printf '%s' "$text2" | grep -qi 'handoff\|alpha\|beta\|gamma\|Did you mean' \
  || fail "clarify text missing suggestions: $text2"
RUN2="$(echo "$OUT2" | jq -r .runDir)"
[ ! -f "$RUN2/skill.txt" ] || fail "skill.txt must not exist on clarify"
pass "unresolved /handof → clarify + no skill.txt"

# ── Body truncation ──────────────────────────────────────────────────────────
# Write a 100000-byte skill body
{
  printf '%s\n' '---'
  printf '%s\n' 'name: bigskill'
  printf '%s\n' 'description: Big skill.'
  printf '%s\n' '---'
  printf '%s\n' ''
  # ~100k of X
  python3 -c 'print("X"*100000)'
} > "$FIXTURE/.claude/skills/handoff/SKILL.md"
# repoint: create bigskill skill
mkdir -p "$FIXTURE/.claude/skills/bigskill"
{
  printf '%s\n' '---'
  printf '%s\n' 'name: bigskill'
  printf '%s\n' 'description: Big skill.'
  printf '%s\n' '---'
  printf '%s\n' ''
  python3 -c 'print("Y"*100000)'
} > "$FIXTURE/.claude/skills/bigskill/SKILL.md"

OUT3="$(printf '%s' "$(req_for '/bigskill')" | HQ_SESSION_SKILL_BODY_MAX_BYTES=65536 \
  bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err3")" || \
  fail "trunc dispatch failed: $(cat "$TMP/err3")"
RUN3="$(echo "$OUT3" | jq -r .runDir)"
[ -f "$RUN3/skill.txt" ] || fail "skill.txt missing for bigskill"
# size = 65536 + truncation marker (marker adds more than 65536)
sz="$(wc -c < "$RUN3/skill.txt" | tr -d '[:space:]')"
[ "$sz" -gt 65536 ] || fail "expected skill.txt > 65536 with marker, got $sz"
[ "$sz" -lt 100000 ] || fail "skill.txt not truncated, size=$sz"
grep -q 'truncated' "$RUN3/skill.txt" || fail "truncation marker missing"
sbt="$(echo "$OUT3" | jq -r '.skillBodyTruncated // false')"
[ "$sbt" = "true" ] || fail "skillBodyTruncated=$sbt want true"
pass "body truncation + skillBodyTruncated"

# ── Contract doc trust classification ────────────────────────────────────────
DOC="$SRC_ROOT/core/knowledge/public/hq-core/agent-session-contract.md"
grep -qi 'skill body' "$DOC" || fail "contract doc missing 'skill body'"
grep -q 'TRUSTED' "$DOC" || fail "contract doc missing TRUSTED classification"
grep -qi 'rescue\|sync' "$DOC" || fail "contract doc missing rescue/sync reason"
pass "contract doc skill body TRUSTED classification"

echo
echo "PASS (skill dispatch)"
