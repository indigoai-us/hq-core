#!/usr/bin/env bash
# inject-policy-always-inject.test.sh
#
# Covers the `inject:` cadence switch (once | always) and the PreCompact ledger
# purge:
#   - inject: once (default) fires at most once per SESSION.
#   - inject: always re-fires once per TURN (each UserPromptSubmit), and is
#     deduped across a turn's mid-turn Bash calls (not once per event).
#   - purge-policy-ledger-precompact.sh clears the session ledgers so a `once`
#     policy re-injects after a compaction.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
PURGE="$ROOT/.claude/hooks/purge-policy-ledger-precompact.sh"
PASS=0
FAIL=0
ok() { echo "  ok $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null || { echo "jq required"; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/hq/core/policies" "$tmp/hq/core/scripts" "$tmp/hq/.claude/hooks" \
  "$tmp/hq/workspace/orchestrator/policy-trigger-state"

# Stub the helper the hooks source for session_id / event extraction.
cat > "$tmp/hq/core/scripts/hook-lib.sh" <<'EOF'
hq_json_get() {
  local key="$1"
  jq -r --arg k "$key" '
    if $k == "hook_event_name" or $k == "session_id" or $k == "tool_name" or $k == "cwd" then
      .[$k] | if . == null or type == "object" or type == "array" then "" else tostring end
    else "" end
  '
}
EOF
printf '#!/bin/bash\necho always\n' > "$tmp/hq/core/scripts/derive-trigger-facts.sh"
printf '#!/bin/bash\nexit 0\n' > "$tmp/hq/core/scripts/eval-trigger.sh"
chmod +x "$tmp/hq/core/scripts/"*.sh
cp "$HOOK" "$tmp/hq/.claude/hooks/inject-policy-on-trigger.sh"
cp "$PURGE" "$tmp/hq/.claude/hooks/purge-policy-ledger-precompact.sh"

# A once-per-session policy (default cadence) and an always (per-turn) policy.
cat > "$tmp/hq/core/policies/once-rule.md" <<'EOF'
---
id: once-rule
when: always
on: [SessionStart]
enforcement: soft
---
## Rule
Fires once per session.
EOF
cat > "$tmp/hq/core/policies/always-rule.md" <<'EOF'
---
id: always-rule
when: always
on: [SessionStart]
enforcement: soft
inject: always
---
## Rule
Re-injects every turn.
EOF

sid="cadence-$$"

# run_event <event> <tool>  → hook output for one event in session $sid.
run_event() {
  local ev="$1" tool="${2:-}"
  local input
  input="$(jq -cn --arg sid "$sid" --arg cwd "$tmp/hq" --arg ev "$ev" --arg tool "$tool" \
    '{session_id:$sid,hook_event_name:$ev,cwd:$cwd,tool_name:$tool,prompt:"hi",tool_input:{command:"ls"}}')"
  cd "$tmp/hq" && HQ_ROOT="$tmp/hq" CLAUDE_PROJECT_DIR="$tmp/hq" \
    bash "$tmp/hq/.claude/hooks/inject-policy-on-trigger.sh" <<<"$input" 2>/dev/null || true
}
has() { printf '%s' "$1" | grep -q "\`$2\`"; }

# Turn 1 (UserPromptSubmit): both policies surface.
t1="$(run_event UserPromptSubmit)"
has "$t1" once-rule && ok "turn1: once-rule injected" || bad "turn1: once-rule missing"
has "$t1" always-rule && ok "turn1: always-rule injected" || bad "turn1: always-rule missing"

# Turn 2 (UserPromptSubmit, same session): once is suppressed, always re-fires.
t2="$(run_event UserPromptSubmit)"
has "$t2" once-rule && bad "turn2: once-rule should be deduped for the session" || ok "turn2: once-rule correctly suppressed"
has "$t2" always-rule && ok "turn2: always-rule re-injected on new turn" || bad "turn2: always-rule missing"

# Mid-turn Bash within turn 2: always must NOT repeat (once per turn, not per event).
b2="$(run_event PreToolUse Bash)"
has "$b2" always-rule && bad "mid-turn: always-rule repeated within the same turn" || ok "mid-turn: always-rule deduped within turn"
has "$b2" once-rule && bad "mid-turn: once-rule reappeared" || ok "mid-turn: once-rule still suppressed"

# PreCompact purge, then a new turn: once-rule comes back.
purge_input="$(jq -cn --arg sid "$sid" '{session_id:$sid,hook_event_name:"PreCompact",trigger:"auto"}')"
HQ_ROOT="$tmp/hq" CLAUDE_PROJECT_DIR="$tmp/hq" \
  bash "$tmp/hq/.claude/hooks/purge-policy-ledger-precompact.sh" <<<"$purge_input" >/dev/null 2>&1 || true
[ ! -f "$tmp/hq/workspace/orchestrator/policy-trigger-state/$sid.txt" ] \
  && ok "purge: session ledger removed" || bad "purge: session ledger still present"

t3="$(run_event UserPromptSubmit)"
has "$t3" once-rule && ok "post-compact: once-rule re-injected after purge" || bad "post-compact: once-rule did not return"
has "$t3" always-rule && ok "post-compact: always-rule injected" || bad "post-compact: always-rule missing"

# Purge with NO session id must delete nothing (never wipe the whole dir).
othersid="other-$$"
printf 'x\n' > "$tmp/hq/workspace/orchestrator/policy-trigger-state/$othersid.txt"
HQ_ROOT="$tmp/hq" CLAUDE_PROJECT_DIR="$tmp/hq" \
  bash "$tmp/hq/.claude/hooks/purge-policy-ledger-precompact.sh" <<<'{}' >/dev/null 2>&1 || true
[ -f "$tmp/hq/workspace/orchestrator/policy-trigger-state/$othersid.txt" ] \
  && ok "purge: no session id → other sessions untouched" || bad "purge: wiped state without a session id"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
