#!/usr/bin/env bash
# PreToolUse hook on Write/Edit/MultiEdit.
# If a /deep-plan invocation is active in this session AND the target file_path
# is under ~/.claude/plans/, reject the write — deep-plan writes belong under
# companies/{co}/projects/{name}/, never in built-in plan-mode storage.

set -uo pipefail

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
MARKER_DIR="${HQ_ROOT}/workspace/orchestrator/policy-trigger-state"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

SESSION_ID="$(printf '%s' "$INPUT" | hq_json_get session_id)"

[ -z "$SESSION_ID" ] && exit 0

MARKER="${MARKER_DIR}/${SESSION_ID}.deep-plan-active"
[ -f "$MARKER" ] || exit 0

# Extract file_path from tool_input (Write/Edit/MultiEdit all use file_path).
FILE_PATH="$(printf '%s' "$INPUT" | hq_json_get tool_input.file_path)"

[ -z "$FILE_PATH" ] && exit 0

# Match ~/.claude/plans/, /Users/*/.claude/plans/, or any *.claude/plans/* path.
case "$FILE_PATH" in
  *"/.claude/plans/"*|"$HOME/.claude/plans/"*|"~/.claude/plans/"*)
    cat >&2 <<MSG
/deep-plan in progress — writes to ~/.claude/plans/ are forbidden.

Attempted write: ${FILE_PATH}

The deep-plan skill writes to:
  - companies/{co}/projects/{name}/prd.json
  - companies/{co}/projects/{name}/README.md
  - companies/{co}/board.json

Built-in plan-mode files (~/.claude/plans/*.md) are a different feature.
Re-route this write to the correct project directory, or re-read
.claude/commands/deep-plan.md HARD RULES.
MSG
    exit 2
    ;;
esac

exit 0
