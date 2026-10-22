#!/usr/bin/env bash
# Regression (feedback 608fd270): the Claude desktop app refuses to send a
# message that starts with a slash command and contains another slash command,
# so `/startwork {co} /deep-plan ...` cannot be sent there. /startwork must
# accept the bare skill name (`/startwork {co} deep-plan ...`), the deep-plan
# routing hook must detect it, and startwork's option lists must not tell users
# to chain two slash commands in one message.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/route-deep-plan-to-skill.sh"
SKILL="$ROOT/.claude/skills/startwork/SKILL.md"
POLICY="$ROOT/core/policies/deep-plan-skill-routing.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

run_hook() {
  local prompt="$1"
  jq -nc --arg p "$prompt" '{prompt: $p, session_id: "sess-608"}' \
    | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK"
}

echo "[1] the reporter's desktop form routes to deep-plan"
out="$(run_hook '/startwork newyorkny deep-plan apps/web onboarding flow')"
printf '%s' "$out" | grep >/dev/null '<deep-plan-routing>' || fail "bare deep-plan in /startwork args was not routed: $out"
[ -f "$TMP/workspace/orchestrator/policy-trigger-state/sess-608.deep-plan-active" ] \
  || fail "deep-plan marker not written for the bare form"
pass "/startwork {co} deep-plan ... routes"

echo "[2] the slash form still routes"
rm -rf "$TMP/workspace"
out="$(run_hook '/startwork newyorkny /deep-plan apps/web onboarding flow')"
printf '%s' "$out" | grep >/dev/null '<deep-plan-routing>' || fail "/deep-plan in /startwork args was not routed"
pass "/startwork {co} /deep-plan ... routes"

echo "[3] the bare word outside /startwork, or inside another word, does not route"
rm -rf "$TMP/workspace"
for p in 'write a deep-plan doc for the team' '/startwork acme review the deep-planning notes' '/startwork acme deep-plans archive'; do
  out="$(run_hook "$p")"
  [ -z "$out" ] || fail "routed a prompt that does not ask for deep-plan: $p"
done
[ ! -d "$TMP/workspace/orchestrator/policy-trigger-state" ] || fail "marker written for a non-routing prompt"
pass "no false routing"

echo "[4] startwork accepts bare skill names and never suggests chained slash commands"
grep -qF 'Bare skill names count the same.' "$SKILL" || fail "startwork SKILL.md lacks the bare skill-name rule"
grep -qF 'Run /prd for full options' "$SKILL" && fail "startwork still offers 'Run /prd for full options'"
grep -qF 'Never suggest a message that chains two slash commands' "$SKILL" || fail "startwork SKILL.md lacks the no-chained-slash rule"
grep -qF 'A bare `deep-plan` token in `/startwork` arguments counts the same' "$POLICY" || fail "deep-plan routing policy lacks the bare-token rule"
pass "skill and policy text"

echo "ALL PASS: startwork-desktop-skill-args"
