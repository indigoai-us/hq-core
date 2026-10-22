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

[ -x "$HELPER" ] || exit 0

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

# Resolve THIS session's project only. The machine-global
# .claude/state/active-session-project pointer is whatever project was last
# active anywhere on the box, so reading it filed a new chat's plan under the
# previous chat's project (feedback_9929d112-27a0-4fb7-9360-cabbb7a6015a).
# auto-session-project.sh publishes the per-session resolution to
# .claude/state/auto-session-project-<session key>; no entry means no project.
SESSION_ID="$(printf '%s' "$STDIN_JSON" | hq_json_get session_id)"
[ -n "$SESSION_ID" ] || SESSION_ID="$(printf '%s' "$STDIN_JSON" | hq_json_get sessionId)"
[ -n "$SESSION_ID" ] || SESSION_ID="${HQ_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}}"
SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -d '[:space:]')"
[ -n "$SESSION_ID" ] || exit 0
case "$SESSION_ID" in
  *..*|*/*|*\\*) exit 0 ;;
esac
SESSION_KEY="${SESSION_ID//[^A-Za-z0-9._-]/_}"
MARKER="$HQ_ROOT/.claude/state/auto-session-project-$SESSION_KEY"
[ -f "$MARKER" ] || exit 0
PROJECT_DIR="$(head -n 1 "$MARKER" 2>/dev/null | tr -d '\r')"
[ -n "$PROJECT_DIR" ] || exit 0
# The marker holds an absolute path; the helper compares against the canonical
# HQ root, so hand it the HQ-relative form.
case "$PROJECT_DIR" in
  "$HQ_ROOT"/*) PROJECT_DIR="${PROJECT_DIR#"$HQ_ROOT"/}" ;;
esac

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

printf '%s\n' "$body" | "$HELPER" ingest-plan --project "$PROJECT_DIR" --source native-plan-tool >/dev/null 2>&1 || true

exit 0
