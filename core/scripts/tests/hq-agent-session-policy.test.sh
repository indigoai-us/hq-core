#!/usr/bin/env bash
# hq-core: public
# US-406: policy inject into system.txt — collision precedence + overrides,
# truncation reporting, hard-before-soft ordering.
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
  "$FIXTURE/companies/indigo/policies" \
  "$FIXTURE/companies/indigo/settings" \
  "$FIXTURE/workspace/sessions" \
  "$FIXTURE/workspace/orchestrator/policy-trigger-state" \
  "$FIXTURE/.claude/hooks" \
  "$FIXTURE/personal/policies"

cp "$SRC_ROOT/core/core.yaml" "$FIXTURE/core/core.yaml"
cp "$SRC_ROOT/core/schemas/"*.json "$FIXTURE/core/schemas/"
cp "$SRC_ROOT/core/scripts/hq-agent-session.sh" "$FIXTURE/core/scripts/"
cp -R "$SRC_ROOT/core/scripts/lib" "$FIXTURE/core/scripts/lib"
cp "$SRC_ROOT/core/scripts/hq-session.sh" "$FIXTURE/core/scripts/" 2>/dev/null || true
cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/" 2>/dev/null || true
cp "$SRC_ROOT/.claude/hooks/inject-policy-on-trigger.sh" "$FIXTURE/.claude/hooks/"
# helpers for the hook
cat > "$FIXTURE/core/scripts/hook-lib.sh" <<'EOF'
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
# Stub derive so `when: always` matches (real derive is event-specific and
# does not emit the synthetic `always` token the policies under test use).
printf '#!/bin/bash\necho always\n' > "$FIXTURE/core/scripts/derive-trigger-facts.sh"
printf '#!/bin/bash\nexit 0\n' > "$FIXTURE/core/scripts/eval-trigger.sh"
# hook-lib.sh is required by inject-policy-on-trigger.sh
# (already written above)
# Minimal channel formats + charter
printf '# Formats\n\n## slack\n\nSlack format.\n' \
  > "$FIXTURE/core/knowledge/public/hq-core/channel-writing-formats.md"
printf 'CHARTER\n' > "$FIXTURE/AGENTS.md"
printf 'COMPANY\n' > "$FIXTURE/companies/indigo/CLAUDE.md"

chmod +x "$FIXTURE/core/scripts/"*.sh "$FIXTURE/core/scripts/lib/"*.sh \
  "$FIXTURE/.claude/hooks/"*.sh 2>/dev/null || true

export HOME="$TMP/home"
mkdir -p "$HOME"
export HQ_AGENT_WORKDIR="$FIXTURE"
export HQ_AGENT_SESSION_SKIP_PROVIDER=1

write_pol() {
  local file="$1" id="$2" enf="$3" rule="$4"
  local enf_line=""
  [ -n "$enf" ] && enf_line="enforcement: $enf"
  cat > "$file" <<EOF
---
id: $id
when: always
on: [SessionStart, UserPromptSubmit]
$enf_line
---

## Rule

$rule
EOF
}

# ── Collision: company wins, policyOverrides records both paths ─────────────
write_pol "$FIXTURE/core/policies/collide-me.md" "collide-me" "hard" "CORE_COPY_MARKER core rule."
write_pol "$FIXTURE/companies/indigo/policies/collide-me.md" "collide-me" "soft" "COMPANY_COPY_MARKER company rule."
write_pol "$FIXTURE/core/policies/core-only.md" "core-only" "soft" "CORE_ONLY_MARKER."

REQ="$(jq -nc '{
  contractVersion: 1,
  agentUid: "agt_test",
  companySlug: "indigo",
  channel: "slack",
  convKey: "agt_test#slack:C1",
  messageText: "do the work",
  provider: "claude",
  sender: {verified: true}
}')"

OUT="$(printf '%s' "$REQ" | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err1")" || \
  fail "session failed: $(cat "$TMP/err1")"
RUN="$(echo "$OUT" | jq -r .runDir)"
[ -f "$RUN/system.txt" ] || fail "no system.txt"
grep -q '<!-- hq-section: policies -->' "$RUN/system.txt" || fail "policies delimiter missing"
grep -q 'COMPANY_COPY_MARKER' "$RUN/system.txt" || fail "company rule not in system.txt"
grep -q 'CORE_COPY_MARKER' "$RUN/system.txt" && fail "core rule leaked into system.txt"
# user.txt must not contain injected rule text
if grep -q 'COMPANY_COPY_MARKER\|CORE_COPY_MARKER' "$RUN/user.txt"; then
  fail "policy text leaked into user.txt"
fi
# policyOverrides
ov_len="$(echo "$OUT" | jq '.policyOverrides // [] | length')"
[ "$ov_len" -ge 1 ] || fail "expected policyOverrides entry: $OUT"
oid="$(echo "$OUT" | jq -r '.policyOverrides[0].id')"
[ "$oid" = "collide-me" ] || fail "override id=$oid"
echo "$OUT" | jq -e '.policyOverrides[0].companyPath | test("companies/indigo")' >/dev/null \
  || fail "companyPath not under companies/indigo"
echo "$OUT" | jq -e '.policyOverrides[0].corePath | test("core/policies")' >/dev/null \
  || fail "corePath not under core/policies"
pass "collision company wins + policyOverrides"

# ── Truncation reporting ────────────────────────────────────────────────────
# three policies, cap 2
write_pol "$FIXTURE/core/policies/t-a.md" "t-a" "soft" "TRUNC_A"
write_pol "$FIXTURE/core/policies/t-b.md" "t-b" "soft" "TRUNC_B"
write_pol "$FIXTURE/core/policies/t-c.md" "t-c" "soft" "TRUNC_C"
# remove collision fixtures to keep count simple
rm -f "$FIXTURE/core/policies/collide-me.md" "$FIXTURE/companies/indigo/policies/collide-me.md" \
  "$FIXTURE/core/policies/core-only.md"

OUT2="$(HQ_SESSION_POLICY_MAX_POLICIES=2 printf '%s' "$REQ" | \
  HQ_SESSION_POLICY_MAX_POLICIES=2 bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err2")" || \
  fail "trunc session failed: $(cat "$TMP/err2")"
ec=0
printf '%s' "$REQ" | HQ_SESSION_POLICY_MAX_POLICIES=2 \
  bash "$FIXTURE/core/scripts/hq-agent-session.sh" >"$TMP/out2" 2>"$TMP/err2b" || ec=$?
[ "$ec" = "0" ] || fail "truncation must exit 0, got $ec"
OUT2="$(cat "$TMP/out2")"
trunc="$(echo "$OUT2" | jq -r '.policiesTruncated // 0')"
# at least t-a,t-b,t-c = 3 with cap 2 → truncated >= 1
[ "$trunc" -ge 1 ] || fail "expected policiesTruncated >= 1 got $trunc: $OUT2"
RUN2="$(echo "$OUT2" | jq -r .runDir)"
grep -q 'withheld\|truncated' "$RUN2/system.txt" || fail "truncation notice missing from system.txt"
pass "truncation reporting (policiesTruncated=$trunc, exit 0)"

# ── hard-before-soft under cap=1 ─────────────────────────────────────────────
rm -f "$FIXTURE/core/policies/"*.md "$FIXTURE/companies/indigo/policies/"*.md
write_pol "$FIXTURE/core/policies/soft-one.md" "soft-one" "soft" "SOFT_MARKER_ONLY"
write_pol "$FIXTURE/core/policies/hard-one.md" "hard-one" "hard" "HARD_MARKER_ONLY"

OUT3="$(printf '%s' "$REQ" | HQ_SESSION_POLICY_MAX_POLICIES=1 \
  bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err3")" || \
  fail "hard-order session failed: $(cat "$TMP/err3")"
RUN3="$(echo "$OUT3" | jq -r .runDir)"
grep -q 'HARD_MARKER_ONLY' "$RUN3/system.txt" || fail "hard policy not injected under cap=1"
grep -q 'SOFT_MARKER_ONLY' "$RUN3/system.txt" && fail "soft policy should be truncated under cap=1"
pass "hard-before-soft under MAX_POLICIES=1"

echo
echo "PASS (policy inject)"
