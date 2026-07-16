#!/usr/bin/env bash
# PostToolUse hook: copy approved native plan material into the active project.
#
# Claude Code exposes ExitPlanMode as a tool. Codex may surface update_plan
# through the hook adapter. Both are treated as plan material worth archiving
# under the active session project.

set -uo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
HELPER="$HQ_ROOT/core/scripts/session-project.sh"
POINTER="$HQ_ROOT/.claude/state/active-session-project"

[ -x "$HELPER" ] || exit 0
[ -f "$POINTER" ] || exit 0

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

tool="$(printf '%s' "$STDIN_JSON" | hq_json_get tool_name)"
body=""
case "$tool" in
  ExitPlanMode)
    for key in plan content summary; do
      body="$(printf '%s' "$STDIN_JSON" | hq_json_get "tool_input.$key")"
      [ -n "$body" ] && break
    done
    if [ -z "$body" ] && command -v jq >/dev/null 2>&1; then
      # Pretty-printed response, but only when it is non-empty (mirrors the
      # old truthiness check: null / "" / {} / [] all count as empty).
      body="$(printf '%s' "$STDIN_JSON" | jq '
        (.tool_response // .tool_output)
        | if . == null or . == "" or . == {} or . == [] then empty else . end' 2>/dev/null || true)"
    fi
    ;;
  update_plan)
    if command -v jq >/dev/null 2>&1; then
      body="$(printf '%s' "$STDIN_JSON" | jq '
        .tool_input | if . == null then empty else . end' 2>/dev/null || true)"
    fi
    ;;
esac

[ -n "$body" ] || exit 0

printf '%s\n' "$body" | "$HELPER" ingest-plan --source native-plan-tool >/dev/null 2>&1 || true

exit 0
