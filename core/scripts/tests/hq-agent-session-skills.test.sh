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
  "$FIXTURE/personal/policies" \
  "$FIXTURE/personal/knowledge/public/agent-capabilities" \
  "$FIXTURE/companies/indigo" \
  "$FIXTURE/.claude/hooks" \
  "$TMP/cli/bin" \
  "$TMP/cli/node_modules/@indigoai-us/hq-flags-client" \
  "$TMP/cli/node_modules/@indigoai-us/hq-cloud"

cp "$SRC_ROOT/core/core.yaml" "$FIXTURE/core/core.yaml"
cp "$SRC_ROOT/core/schemas/"*.json "$FIXTURE/core/schemas/"
cp "$SRC_ROOT/core/scripts/hq-agent-session.sh" "$FIXTURE/core/scripts/"
cp -R "$SRC_ROOT/core/scripts/lib" "$FIXTURE/core/scripts/lib"
cp "$SRC_ROOT/core/scripts/hq-session.sh" "$FIXTURE/core/scripts/" 2>/dev/null || true
cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/" 2>/dev/null || true
cp "$SRC_ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIXTURE/.claude/hooks/"
cp "$SRC_ROOT/.claude/hooks/inject-policy-on-trigger.sh" "$FIXTURE/.claude/hooks/"
if [ -f "$SRC_ROOT/.claude/hooks/agent-session-skill-catalog-compact-flag.cjs" ]; then
  cp "$SRC_ROOT/.claude/hooks/agent-session-skill-catalog-compact-flag.cjs" "$FIXTURE/.claude/hooks/"
fi
cat > "$FIXTURE/core/scripts/hook-lib.sh" <<'EOF'
hq_json_get() {
  jq -r --arg k "$1" '
    if $k == "hook_event_name" or $k == "session_id" or $k == "tool_name" or $k == "cwd" then
      .[$k] | if . == null or type == "object" or type == "array" then "" else tostring end
    else "" end'
}
EOF
printf '#!/bin/bash\necho always\n' > "$FIXTURE/core/scripts/derive-trigger-facts.sh"
printf '#!/bin/bash\nexit 0\n' > "$FIXTURE/core/scripts/eval-trigger.sh"
printf '# Formats\n\n## slack\n\nSlack.\n' \
  > "$FIXTURE/core/knowledge/public/hq-core/channel-writing-formats.md"
printf 'CHARTER\n' > "$FIXTURE/AGENTS.md"
printf 'COMPANY\n' > "$FIXTURE/companies/indigo/CLAUDE.md"
printf 'cmp_test123456\n' > "$FIXTURE/companies/indigo/.company-uid"
printf 'AGENT_IDENTITY_CONTEXT\n' \
  > "$FIXTURE/personal/knowledge/public/agent-capabilities/hq-agent-contract.md"
# Keep policy injection deterministic and offline for the synthetic fixture.
cat > "$FIXTURE/.claude/hooks/inject-policy-on-trigger.sh" <<'HOOK'
#!/usr/bin/env bash
printf 'fixture-hard-safety\tcompany\t\thard\tFIXTURE_HARD_POLICY\n'
HOOK

# Synthetic hq-flags client: tests stay offline and can exercise both flag values.
printf '#!/bin/bash\nexit 0\n' > "$TMP/cli/bin/hq"
chmod +x "$TMP/cli/bin/hq"
cat > "$TMP/cli/package.json" <<'JSON'
{"name":"@indigoai-us/hq-cli"}
JSON
cat > "$TMP/cli/node_modules/@indigoai-us/hq-flags-client/package.json" <<'JSON'
{"name":"@indigoai-us/hq-flags-client","main":"index.cjs"}
JSON
cat > "$TMP/cli/node_modules/@indigoai-us/hq-flags-client/index.cjs" <<'JS'
exports.createFlagClient = () => ({
  ready: async () => {},
  snapshot: () => ({flags: process.env.HQ_TEST_SESSION_SKILL_CATALOG_COMPACT === "true"
    ? {"core.agent-session-skill-catalog-compact": true}
    : {"core.agent-session-skill-catalog-compact": false}}),
  close: () => {},
});
JS
cat > "$TMP/cli/node_modules/@indigoai-us/hq-cloud/package.json" <<'JSON'
{"name":"@indigoai-us/hq-cloud","main":"index.cjs"}
JSON
cat > "$TMP/cli/node_modules/@indigoai-us/hq-cloud/index.cjs" <<'JS'
exports.loadCachedTokens = () => ({idToken: "synthetic-token"});
JS

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
export HQ_CLI_BIN="$TMP/cli/bin/hq"
export HQ_FLAGS_API_URL="https://flags.synthetic.test"
export HQ_COMPANY_UID="cmp_test123456"
export HQ_COMPANY_SLUG="indigo"
export HQ_TEST_SESSION_SKILL_CATALOG_COMPACT=false

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
for i in $(seq 1 40); do
  grep -Eq "^- /bulk-$i( —|$)" "$RUN2/system.txt" || \
    fail "bulk-$i missing even though every name-only entry fits"
done
grep -Eq '^- /pack-skill( —|$)' "$RUN2/system.txt" || \
  fail "tail package skill missing even though every name-only entry fits"
bulk_descriptions="$(grep -c 'with enough text to consume catalog budget' "$RUN2/system.txt" || true)"
[ "$bulk_descriptions" -lt 40 ] || \
  fail "descriptions should be shortened before a skill name is omitted"

# The exported rendered byte count matches the actual catalog body exactly.
# Source the public catalog seam directly because the session response exposes
# the available count, while consumers use this byte count from library state.
# shellcheck source=../lib/session-skill-catalog.sh
source "$FIXTURE/core/scripts/lib/session-skill-catalog.sh"
HQ_SESSION_SKILL_CATALOG_MAX_BYTES=1024
session_skill_catalog_build "$FIXTURE" indigo >/dev/null
body_bytes="$(printf '%s\n' "$SESSION_SKILL_CATALOG_BODY" | wc -c | tr -d '[:space:]')"
[ "$SESSION_SKILL_CATALOG_RENDERED_BYTES" = "$body_bytes" ] || \
  fail "rendered byte count=$SESSION_SKILL_CATALOG_RENDERED_BYTES actual=$body_bytes"
[ "$SESSION_SKILL_CATALOG_RENDERED_BYTES" -le 1024 ] || \
  fail "exported rendered byte count exceeds cap"
pass "catalog preserves tail names (rendered=$body_bytes, available=$avail2)"

# If the name-only catalog itself cannot fit, say so within the same byte cap.
HQ_SESSION_SKILL_CATALOG_MAX_BYTES=180
session_skill_catalog_build "$FIXTURE" indigo >/dev/null
printf '%s\n' "$SESSION_SKILL_CATALOG_BODY" | grep -q 'catalog truncated' || \
  fail "name-only overflow must render a truncation indicator"
overflow_bytes="$(printf '%s\n' "$SESSION_SKILL_CATALOG_BODY" | wc -c | tr -d '[:space:]')"
[ "$SESSION_SKILL_CATALOG_RENDERED_BYTES" = "$overflow_bytes" ] || \
  fail "overflow byte count=$SESSION_SKILL_CATALOG_RENDERED_BYTES actual=$overflow_bytes"
[ "$overflow_bytes" -le 180 ] || fail "overflow catalog $overflow_bytes bytes > 180"
pass "name-only overflow is explicit (rendered=$overflow_bytes)"

# Flag-off retains the current catalog; flag-on replaces it with a short pointer
# to the allowed SKILL.md locations while keeping all safety sections intact.
HQ_TEST_SESSION_SKILL_CATALOG_COMPACT=false
REQ_COMPACT="$(echo "$REQ" | jq '.provider = "grok"')"
OUT_OFF="$(printf '%s' "$REQ_COMPACT" | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err-off")" || \
  fail "flag-off session failed: $(cat "$TMP/err-off")"
RUN_OFF="$(echo "$OUT_OFF" | jq -r .runDir)"
grep -q -- '- /handoff — Preserve session state' "$RUN_OFF/system.txt" || \
  fail "flag-off must preserve the existing skill catalog"
pass "flag-off retains the existing catalog"

HQ_TEST_SESSION_SKILL_CATALOG_COMPACT=true
OUT_ON="$(printf '%s' "$REQ_COMPACT" | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err-on")" || \
  fail "flag-on session failed: $(cat "$TMP/err-on")"
RUN_ON="$(echo "$OUT_ON" | jq -r .runDir)"
SYS_ON="$RUN_ON/system.txt"
section_bytes() {
  local file="$1" section="$2"
  awk -v marker="<!-- hq-section: $section -->" '
    $0 == marker {print; grab=1; next}
    grab && /<!-- hq-section:/ {exit}
    grab {print}
  ' "$file" | wc -c | tr -d '[:space:]'
}
for safety_section in charter agent-contract company-charter voice channel-format policies \
  brief-posture reply-contract mention-posture status-notes durable-writes reply-contract-reminder; do
  before_bytes="$(section_bytes "$RUN_OFF/system.txt" "$safety_section")"
  after_bytes="$(section_bytes "$SYS_ON" "$safety_section")"
  [ "$before_bytes" = "$after_bytes" ] || \
    fail "flag-on changed safety section $safety_section bytes ($before_bytes -> $after_bytes)"
  printf 'MEASURE section=%s bytes_before=%s bytes_after=%s\n' \
    "$safety_section" "$before_bytes" "$after_bytes"
done
catalog_bytes_before="$(section_bytes "$RUN_OFF/system.txt" skill-catalog)"
catalog_bytes_after="$(section_bytes "$SYS_ON" skill-catalog)"
printf 'MEASURE section=skill-catalog bytes_before=%s bytes_after=%s\n' \
  "$catalog_bytes_before" "$catalog_bytes_after"
for phase in system-prompt policy skill-catalog; do
  before_ms="$(echo "$OUT_OFF" | jq -r --arg phase "$phase" '.assemblyMs[$phase] // 0')"
  after_ms="$(echo "$OUT_ON" | jq -r --arg phase "$phase" '.assemblyMs[$phase] // 0')"
  printf 'MEASURE phase=%s ms_before=%s ms_after=%s\n' "$phase" "$before_ms" "$after_ms"
done
compact_bytes="$(awk '
  /<!-- hq-section: skill-catalog -->/ {grab=1; next}
  /<!-- hq-section:/ {if(grab) exit}
  grab {print}
' "$SYS_ON" | wc -c | tr -d '[:space:]')"
[ "$compact_bytes" -lt 512 ] || fail "flag-on skill catalog is not compact ($compact_bytes bytes)"
grep -qF 'Read the relevant SKILL.md' "$SYS_ON" || fail "compact guidance does not point to SKILL.md files"
grep -qF '.claude/skills' "$SYS_ON" || fail "compact guidance omits root skill path"
grep -qF 'companies/indigo/skills' "$SYS_ON" || fail "compact guidance omits bound-company skill path"
grep -qF 'core/packages' "$SYS_ON" || fail "compact guidance omits packaged skill path"
grep -qF 'Do not inspect another company directory' "$SYS_ON" || fail "compact guidance omits tenant scope boundary"
grep -qF 'companies/otherco' "$SYS_ON" && fail "compact guidance leaked another company path"
if grep -q 'Company signals skill description\|Root signals skill description\|Package skill one-liner' "$SYS_ON"; then
  fail "flag-on still includes expanded skill descriptions"
fi
for safety_section in charter agent-contract company-charter policies reply-contract reply-contract-reminder; do
  grep -qF "<!-- hq-section: $safety_section -->" "$SYS_ON" || \
    fail "flag-on removed safety section $safety_section"
done
grep -qF 'CHARTER' "$SYS_ON" || fail "flag-on removed charter content"
grep -qF 'COMPANY' "$SYS_ON" || fail "flag-on removed company charter content"
grep -qF 'AGENT_IDENTITY_CONTEXT' "$SYS_ON" || fail "flag-on removed agent identity context"
grep -qF 'FIXTURE_HARD_POLICY' "$SYS_ON" || fail "flag-on removed hard policy content"
pass "flag-on compacts the catalog and preserves safety sections ($compact_bytes bytes)"

echo
echo "PASS (skill catalog)"
