#!/usr/bin/env bash
# hq-core: public
# US-406 / US-409: skill catalog — enumeration, shadowing, cross-company
# isolation, catalog byte cap, skillsAvailable.
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
  "$FIXTURE/companies/indigo/skills/signals" \
  "$FIXTURE/companies/indigo/settings" \
  "$FIXTURE/companies/otherco/skills/secret-other" \
  "$FIXTURE/workspace/sessions" \
  "$FIXTURE/workspace/orchestrator/policy-trigger-state" \
  "$FIXTURE/.claude/hooks" \
  "$FIXTURE/.claude/skills/handoff" \
  "$FIXTURE/.claude/skills/signals" \
  "$FIXTURE/core/packages/demo-pack/skills/pack-skill" \
  "$FIXTURE/personal/policies"

cp "$SRC_ROOT/core/core.yaml" "$FIXTURE/core/core.yaml"
cp "$SRC_ROOT/core/schemas/"*.json "$FIXTURE/core/schemas/"
cp "$SRC_ROOT/core/scripts/hq-agent-session.sh" "$FIXTURE/core/scripts/"
cp -R "$SRC_ROOT/core/scripts/lib" "$FIXTURE/core/scripts/lib"
cp "$SRC_ROOT/core/scripts/hq-session.sh" "$FIXTURE/core/scripts/" 2>/dev/null || true
cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/" 2>/dev/null || true
cp "$SRC_ROOT/.claude/hooks/inject-policy-on-trigger.sh" "$FIXTURE/.claude/hooks/"
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

# Skills
cat > "$FIXTURE/.claude/skills/handoff/SKILL.md" <<'EOF'
---
name: handoff
description: Preserve session state for a follow-up agent.
---

# Handoff body UNIQUE_HANDOFF_BODY_SENTENCE that must not appear in catalog-only turns.
EOF
cat > "$FIXTURE/.claude/skills/signals/SKILL.md" <<'EOF'
---
name: signals
description: Root signals skill description.
---

# Root signals body ROOT_SIGNALS_BODY
EOF
cat > "$FIXTURE/companies/indigo/skills/signals/SKILL.md" <<'EOF'
---
name: signals
description: Company signals skill description.
---

# Company signals body COMPANY_SIGNALS_BODY
EOF
cat > "$FIXTURE/companies/otherco/skills/secret-other/SKILL.md" <<'EOF'
---
name: secret-other
description: Cross-tenant secret skill for isolation checks.
---

# Must never appear for indigo runs. OTHERCO_PATH_MARKER companies/otherco
EOF
cat > "$FIXTURE/core/packages/demo-pack/skills/pack-skill/SKILL.md" <<'EOF'
---
name: pack-skill
description: Package skill one-liner.
---

# Pack body
EOF

chmod +x "$FIXTURE/core/scripts/"*.sh "$FIXTURE/core/scripts/lib/"*.sh \
  "$FIXTURE/.claude/hooks/"*.sh 2>/dev/null || true

export HOME="$TMP/home"
mkdir -p "$HOME"
export HQ_AGENT_WORKDIR="$FIXTURE"
export HQ_AGENT_SESSION_SKIP_PROVIDER=1

REQ="$(jq -nc '{
  contractVersion: 1,
  agentUid: "agt_test",
  companySlug: "indigo",
  channel: "slack",
  convKey: "agt_test#slack:C1",
  messageText: "status please",
  provider: "claude",
  sender: {verified: true}
}')"

OUT="$(printf '%s' "$REQ" | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err")" || \
  fail "session failed: $(cat "$TMP/err")"
RUN="$(echo "$OUT" | jq -r .runDir)"
SYS="$RUN/system.txt"

# handoff listed with description
grep -q 'handoff' "$SYS" || fail "handoff missing from catalog"
grep -q 'Preserve session state' "$SYS" || fail "handoff description missing"
pass "handoff enumerated"

# signals appears exactly once, company description wins
sig_count="$(grep -c '/signals' "$SYS" || true)"
[ "$sig_count" = "1" ] || fail "signals listed $sig_count times (want 1)"
grep -q 'Company signals skill description' "$SYS" || fail "company signals description missing"
grep -q 'Root signals skill description' "$SYS" && fail "root signals description should be shadowed"
pass "company shadows root skill"

# pack-skill from core/packages
grep -q 'pack-skill' "$SYS" || fail "package skill missing"
pass "package skill enumerated"

# no skill body in catalog-only turn
grep -q 'UNIQUE_HANDOFF_BODY_SENTENCE' "$SYS" && fail "skill body inlined in catalog"
pass "no skill bodies in catalog"

# cross-company isolation
grep -q 'companies/otherco' "$SYS" && fail "otherco path leaked"
grep -q 'secret-other' "$SYS" && fail "otherco skill leaked"
grep -q 'OTHERCO_PATH_MARKER' "$SYS" && fail "otherco body leaked"
pass "cross-company isolation"

# skillsAvailable
avail="$(echo "$OUT" | jq -r '.skillsAvailable // empty')"
[ -n "$avail" ] || fail "skillsAvailable missing"
# handoff + signals + pack-skill = 3
[ "$avail" -ge 3 ] || fail "skillsAvailable=$avail expected >= 3"
pass "skillsAvailable=$avail"

# byte cap
# Add many skills to blow a tiny cap
for i in $(seq 1 40); do
  mkdir -p "$FIXTURE/.claude/skills/bulk-$i"
  cat > "$FIXTURE/.claude/skills/bulk-$i/SKILL.md" <<EOF
---
name: bulk-$i
description: Bulk skill number $i with enough text to consume catalog budget bytes quickly when repeated.
---

# body $i
EOF
done
OUT2="$(printf '%s' "$REQ" | HQ_SESSION_SKILL_CATALOG_MAX_BYTES=1024 \
  bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err2")" || \
  fail "cap session failed: $(cat "$TMP/err2")"
ec=0
printf '%s' "$REQ" | HQ_SESSION_SKILL_CATALOG_MAX_BYTES=1024 \
  bash "$FIXTURE/core/scripts/hq-agent-session.sh" >"$TMP/out2" 2>/dev/null || ec=$?
[ "$ec" = "0" ] || fail "catalog cap must exit 0, got $ec"
OUT2="$(cat "$TMP/out2")"
RUN2="$(echo "$OUT2" | jq -r .runDir)"
# Extract skill-catalog section byte size
cat_body="$(awk '
  /<!-- hq-section: skill-catalog -->/ {grab=1; next}
  /<!-- hq-section:/ {if(grab) exit}
  grab {print}
' "$RUN2/system.txt")"
cat_bytes="$(printf '%s' "$cat_body" | wc -c | tr -d '[:space:]')"
[ "$cat_bytes" -le 1024 ] || fail "catalog section $cat_bytes bytes > 1024"
avail2="$(echo "$OUT2" | jq -r '.skillsAvailable')"
[ "$avail2" -ge 40 ] || fail "skillsAvailable should count all entries, got $avail2"
pass "catalog byte cap (rendered=$cat_bytes, available=$avail2)"

echo
echo "PASS (skill catalog)"
