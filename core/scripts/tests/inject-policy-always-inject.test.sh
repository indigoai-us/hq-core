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
cp "$ROOT/.claude/hooks/hook-gate.sh" "$tmp/hq/.claude/hooks/hook-gate.sh"
cp "$ROOT/.claude/hooks/policy-enforcement-gate.sh" "$tmp/hq/.claude/hooks/policy-enforcement-gate.sh"
cp "$PURGE" "$tmp/hq/.claude/hooks/purge-policy-ledger-precompact.sh"
printf '# Launch brief\n' > "$tmp/hq/brief.md"

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
cat > "$tmp/hq/core/policies/outbound-rule.md" <<'EOF'
---
id: outbound-rule
when: always
on: [PreToolUse]
enforcement: hard
required-skill: outbound-review
---
## Rule
ALWAYS load the outbound-review skill before an outbound action.
EOF

sid="cadence-$$"

# run_event <event> <tool>  → hook output for one event in session $sid.
run_event() {
  local ev="$1" tool="${2:-}" prompt="${3:-hi}" command="${4:-ls}"
  local input
  input="$(jq -cn --arg sid "$sid" --arg cwd "$tmp/hq" --arg ev "$ev" --arg tool "$tool" --arg prompt "$prompt" --arg command "$command" \
    '{session_id:$sid,hook_event_name:$ev,cwd:$cwd,tool_name:$tool,prompt:$prompt,tool_input:{command:$command}}')"
  cd "$tmp/hq" && HQ_ROOT="$tmp/hq" CLAUDE_PROJECT_DIR="$tmp/hq" \
    bash "$tmp/hq/.claude/hooks/inject-policy-on-trigger.sh" <<<"$input" 2>/dev/null || true
}
has() {
  local needle
  printf -v needle '\x60%s\x60' "$2"
  [[ "$1" == *"$needle"* ]]
}

# Turn 1 (UserPromptSubmit): both policies surface.
t1="$(run_event UserPromptSubmit '' 'Draft a Slack broadcast from the attached brief brief.md')"
has "$t1" once-rule && ok "turn1: once-rule injected" || bad "turn1: once-rule missing"
has "$t1" always-rule && ok "turn1: always-rule injected" || bad "turn1: always-rule missing"
printf '%s' "$t1" | grep -q 'GOVERNANCE RECEIPTS REQUIRED' \
  && ok "turn1: declaration gate runs after policy selection" \
  || bad "turn1: declaration gate context missing"
enforcement_matches="$tmp/hq/workspace/orchestrator/policy-enforcement/$sid.policies.tsv"
grep -q $'^once-rule\t' "$enforcement_matches" && grep -q $'^always-rule\t' "$enforcement_matches" \
  && ok "turn1: machine-readable enforcement matches persisted" \
  || bad "turn1: enforcement match hand-off missing"
jq -e '.requiredSkills == ["work-broadcast"] and .briefs == ["brief.md"]' \
  "$tmp/hq/workspace/orchestrator/policy-enforcement/$sid.json" >/dev/null \
  && ok "turn1: declared skill and brief persisted in enforcement state" \
  || bad "turn1: declared requirements missing from enforcement state"

# Turn 2 (UserPromptSubmit, same session): once is suppressed, always re-fires.
t2="$(run_event UserPromptSubmit)"
has "$t2" once-rule && bad "turn2: once-rule should be deduped for the session" || ok "turn2: once-rule correctly suppressed"
has "$t2" always-rule && ok "turn2: always-rule re-injected on new turn" || bad "turn2: always-rule missing"
grep -q $'^always-rule\t' "$enforcement_matches" && grep -q $'^once-rule\t' "$enforcement_matches" \
  && ok "turn2: session-baseline enforcement remains active" \
  || bad "turn2: session-baseline enforcement was lost"

blocked="$(run_event PreToolUse Bash hi 'hq dm prs_fixture "update"')"
printf '%s' "$blocked" | grep -q 'Missing skills: outbound-review' \
  && ok "pre-tool: newly matched policy blocks the same outbound action" \
  || bad "pre-tool: newly matched policy raced past enforcement"

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

# A dead holder must be reclaimed so the next governed outbound action can proceed.
STALE_SID="orphan-lock-$$"
STALE_MATCHES="$tmp/hq/workspace/orchestrator/policy-enforcement/$STALE_SID.policies.tsv"
STALE_LOCK="$STALE_MATCHES.lock"
mkdir -p "$STALE_LOCK"
printf '2147483647\n' > "$STALE_LOCK/pid"
date +%s > "$STALE_LOCK/time"
printf 'orphaned-test-lock\n' > "$STALE_LOCK/token"
jq -nc '{requiredSkills:["outbound-review"],briefs:[],receipts:{skills:["outbound-review"],briefs:[]},conflicts:[]}' \
  > "$tmp/hq/workspace/orchestrator/policy-enforcement/$STALE_SID.json"
STALE_INPUT="$(jq -cn --arg sid "$STALE_SID" --arg cwd "$tmp/hq" --arg cmd 'hq dm prs_fixture "update"' \
  '{session_id:$sid,hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')"
set +e
STALE_OUTPUT="$(cd "$tmp/hq" && HQ_ROOT="$tmp/hq" CLAUDE_PROJECT_DIR="$tmp/hq" \
  bash "$tmp/hq/.claude/hooks/inject-policy-on-trigger.sh" <<<"$STALE_INPUT" 2>/dev/null)"
STALE_RC=$?
set -e
[ "$STALE_RC" -eq 0 ] \
  && ok "orphaned policy match lock is reclaimed before outbound check" \
  || bad "orphaned policy match lock blocked outbound check (rc=$STALE_RC; output=$STALE_OUTPUT)"
[ ! -d "$STALE_LOCK" ] \
  && ok "orphaned policy match lock directory is removed" \
  || bad "orphaned policy match lock directory remains"
grep -q $'^outbound-rule\t' "$STALE_MATCHES" \
  && ok "outbound policy match is written after stale lock recovery" \
  || bad "outbound policy match was not written after stale lock recovery"

# A live holder that exceeds the TTL must also be reclaimed.
EXPIRED_SID="expired-lock-$$"
EXPIRED_MATCHES="$tmp/hq/workspace/orchestrator/policy-enforcement/$EXPIRED_SID.policies.tsv"
EXPIRED_LOCK="$EXPIRED_MATCHES.lock"
mkdir -p "$EXPIRED_LOCK"
printf '%s\n' "$$" > "$EXPIRED_LOCK/pid"
printf '%s\n' "$(( $(date +%s) - 31 ))" > "$EXPIRED_LOCK/time"
printf 'expired-test-lock\n' > "$EXPIRED_LOCK/token"
jq -nc '{requiredSkills:["outbound-review"],briefs:[],receipts:{skills:["outbound-review"],briefs:[]},conflicts:[]}' \
  > "$tmp/hq/workspace/orchestrator/policy-enforcement/$EXPIRED_SID.json"
EXPIRED_INPUT="$(jq -cn --arg sid "$EXPIRED_SID" --arg cwd "$tmp/hq" --arg cmd 'hq dm prs_fixture "update"' \
  '{session_id:$sid,hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')"
set +e
EXPIRED_OUTPUT="$(cd "$tmp/hq" && HQ_ROOT="$tmp/hq" CLAUDE_PROJECT_DIR="$tmp/hq" \
  bash "$tmp/hq/.claude/hooks/inject-policy-on-trigger.sh" <<<"$EXPIRED_INPUT" 2>/dev/null)"
EXPIRED_RC=$?
set -e
[ "$EXPIRED_RC" -eq 0 ] \
  && ok "expired live-holder lock is reclaimed before outbound check" \
  || bad "expired live-holder lock blocked outbound check (rc=$EXPIRED_RC; output=$EXPIRED_OUTPUT)"
[ ! -d "$EXPIRED_LOCK" ] \
  && ok "expired policy match lock directory is removed" \
  || bad "expired policy match lock directory remains"
grep -q $'^outbound-rule\t' "$EXPIRED_MATCHES" \
  && ok "outbound policy match is written after TTL recovery" \
  || bad "outbound policy match was not written after TTL recovery"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
