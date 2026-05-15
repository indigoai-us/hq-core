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

body="$(printf '%s' "$STDIN_JSON" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

tool = data.get("tool_name", "")
tool_input = data.get("tool_input") or {}
tool_response = data.get("tool_response") or data.get("tool_output") or {}

if tool == "ExitPlanMode":
    for key in ("plan", "content", "summary"):
        value = tool_input.get(key) if isinstance(tool_input, dict) else ""
        if value:
            print(str(value))
            sys.exit(0)
    if tool_response:
        print(json.dumps(tool_response, indent=2))
elif tool == "update_plan":
    print(json.dumps(tool_input, indent=2))
' 2>/dev/null || true)"

[ -n "$body" ] || exit 0

printf '%s\n' "$body" | "$HELPER" ingest-plan --source native-plan-tool >/dev/null 2>&1 || true

exit 0
