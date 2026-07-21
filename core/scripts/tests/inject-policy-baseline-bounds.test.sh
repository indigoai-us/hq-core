#!/usr/bin/env bash
# inject-policy-baseline-bounds.test.sh — US-003 / former US-013.
# Asserts the SessionStart baseline emitter stays within the box preflight
# caps (SESSION_PREFLIGHT_MAX_POLICIES=16) against a synthetic oversize tree,
# and that truncation is non-silent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
PASS=0
FAIL=0
ok() { echo "  ok $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Synthetic HQ root with >16 SessionStart baseline policies.
mkdir -p "$tmp/hq/core/policies" "$tmp/hq/companies/acme/policies" \
  "$tmp/hq/personal/policies" "$tmp/hq/workspace/orchestrator/policy-trigger-state" \
  "$tmp/hq/core/scripts" "$tmp/hq/.claude/hooks"

# Stub helpers the hook sources / shells out to.
cat > "$tmp/hq/core/scripts/hook-lib.sh" <<'EOF'
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
# derive + eval stubs unused when POLICY_FILES path uses inline awk; still required on disk.
printf '#!/bin/bash\necho always\n' > "$tmp/hq/core/scripts/derive-trigger-facts.sh"
printf '#!/bin/bash\nexit 0\n' > "$tmp/hq/core/scripts/eval-trigger.sh"
chmod +x "$tmp/hq/core/scripts/"*.sh
cp "$HOOK" "$tmp/hq/.claude/hooks/inject-policy-on-trigger.sh"
# Point the copied hook's HELPERS resolution: it walks up from SCRIPT_DIR.
# Our copy lives at $tmp/hq/.claude/hooks so ../../.. is $tmp/hq — good if
# core/scripts is under that. Ensure jq is available.
command -v jq >/dev/null

# 24 core SessionStart baselines (exceeds cap of 16).
for i in $(seq -w 1 24); do
  cat > "$tmp/hq/core/policies/ss-core-$i.md" <<EOF
---
id: ss-core-$i
when: always
on: [SessionStart]
enforcement: soft
---
## Rule
Core baseline $i.
EOF
done
# One company policy that should survive the cap (company precedes core).
cat > "$tmp/hq/companies/acme/policies/company-important.md" <<'EOF'
---
id: company-important
when: always
on: [SessionStart]
enforcement: hard
---
## Rule
Company important baseline.
EOF

sid="bounds-test-$$"
input="$(jq -cn --arg sid "$sid" --arg cwd "$tmp/hq/companies/acme" \
  '{session_id:$sid,source:"startup",hook_event_name:"SessionStart",cwd:$cwd,prompt:"hello"}')"

out="$(
  cd "$tmp/hq/companies/acme" && \
  HQ_ROOT="$tmp/hq" CLAUDE_PROJECT_DIR="$tmp/hq" HQ_SESSION_POLICY_CAP=16 \
    bash "$tmp/hq/.claude/hooks/inject-policy-on-trigger.sh" <<<"$input" 2>/dev/null || true
)"

slug_count="$(printf '%s\n' "$out" | grep -c '> Policy `' || true)"
if [ "$slug_count" -le 16 ] && [ "$slug_count" -ge 1 ]; then
  ok "slug count <= 16 (got $slug_count)"
else
  bad "slug count out of bounds (got $slug_count)"
fi

if printf '%s' "$out" | grep -q 'company-important'; then
  ok "company policy retained under cap"
else
  bad "company policy missing under cap"
fi

if printf '%s' "$out" | grep -q 'withheld'; then
  ok "truncation is non-silent"
else
  bad "truncation notice missing"
fi

# Under-cap tree: no truncation notice.
rm -rf "$tmp/hq/core/policies"
mkdir -p "$tmp/hq/core/policies"
for i in 1 2 3; do
  cat > "$tmp/hq/core/policies/ss-small-$i.md" <<EOF
---
id: ss-small-$i
when: always
on: [SessionStart]
---
## Rule
Small $i.
EOF
done
sid2="bounds-small-$$"
input2="$(jq -cn --arg sid "$sid2" --arg cwd "$tmp/hq/companies/acme" \
  '{session_id:$sid,source:"startup",hook_event_name:"SessionStart",cwd:$cwd,prompt:"hello"}')"
out2="$(
  cd "$tmp/hq/companies/acme" && \
  HQ_ROOT="$tmp/hq" CLAUDE_PROJECT_DIR="$tmp/hq" HQ_SESSION_POLICY_CAP=16 \
    bash "$tmp/hq/.claude/hooks/inject-policy-on-trigger.sh" <<<"$input2" 2>/dev/null || true
)"
if ! printf '%s' "$out2" | grep -q 'withheld'; then
  ok "no truncation notice under cap"
else
  bad "spurious truncation under cap"
fi
small_count="$(printf '%s\n' "$out2" | grep -c '> Policy `' || true)"
if [ "$small_count" -ge 3 ] && [ "$small_count" -le 16 ]; then
  ok "under-cap tree emits all ($small_count)"
else
  bad "under-cap emit wrong ($small_count)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "PASS ($PASS assertions)"
  exit 0
fi
echo "FAIL ($FAIL failed, $PASS passed)"
exit 1
