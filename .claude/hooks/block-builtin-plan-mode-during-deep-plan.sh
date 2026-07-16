#!/usr/bin/env bash
# PreToolUse hook on EnterPlanMode.
# If a /deep-plan invocation is active in this session (marker file present),
# block EnterPlanMode — the deep-plan skill produces companies/{co}/projects/{name}/prd.json,
# never ~/.claude/plans/*.md.
#
# Marker is set by route-deep-plan-to-skill.sh (UserPromptSubmit hook).
# Marker path: $HQ_ROOT/workspace/orchestrator/policy-trigger-state/${SESSION_ID}.deep-plan-active

set -uo pipefail

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
MARKER_DIR="${HQ_ROOT}/workspace/orchestrator/policy-trigger-state"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

# Read PreToolUse JSON from stdin.
INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

SESSION_ID="$(printf '%s' "$INPUT" | hq_json_get session_id)"

[ -z "$SESSION_ID" ] && exit 0

MARKER="${MARKER_DIR}/${SESSION_ID}.deep-plan-active"
if [ -f "$MARKER" ]; then
  cat >&2 <<'MSG'
/deep-plan in progress — built-in plan mode is forbidden.

The deep-plan skill at .claude/skills/deep-plan/SKILL.md produces:
  - companies/{co}/projects/{name}/prd.json (source of truth)
  - companies/{co}/projects/{name}/README.md (derived)
  - companies/{co}/board.json registration entry

Built-in plan mode (~/.claude/plans/*.md) is a different feature and must NOT
be used during /deep-plan. Re-read .claude/commands/deep-plan.md HARD RULES,
then continue executing the deep-plan skill (research subagents → 15-question
3-tier interview → prd.json + board entry → /handoff).

If you genuinely need built-in plan mode, the user must first explicitly
abandon the /deep-plan invocation.
MSG
  exit 2
fi

exit 0
