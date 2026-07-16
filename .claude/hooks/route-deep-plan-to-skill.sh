#!/bin/bash
# route-deep-plan-to-skill.sh — UserPromptSubmit hook
#
# Detects `/deep-plan` token in the user prompt (raw slash-command, embedded
# inside another command's args, or even just mentioned). Two effects:
#
#   1. Writes a per-session marker file at:
#        $HQ_ROOT/workspace/orchestrator/policy-trigger-state/{session_id}.deep-plan-active
#      This signals to PreToolUse hooks (block-builtin-plan-mode-during-deep-plan,
#      block-plans-dir-during-deep-plan) that they should fire in this session.
#
#   2. Injects a `<deep-plan-routing>` system reminder pinning the agent to the
#      `.claude/skills/deep-plan/SKILL.md` skill and forbidding built-in plan
#      mode + auto-execution.
#
# Why both: the marker is the durable state that hard-blocking PreToolUse hooks
# rely on; the additionalContext is the in-band nudge the model sees on the
# very turn where the routing decision happens.
#
# Trigger: UserPromptSubmit
# Exit codes: 0 = always allow (additive context only)
# Dedupe: marker file is idempotent — written every time `/deep-plan` is seen
#         so re-mentions refresh the timestamp.

set -euo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

extract() {
  printf '%s' "$STDIN_JSON" | hq_json_get "$1"
}

PROMPT="$(extract prompt)"
SESSION_ID="$(extract session_id)"

# Token detection — `/deep-plan` as a whole token (not e.g. inside a URL).
# Matches: leading slash, optional whitespace, the literal `/deep-plan`,
# followed by end-of-string, whitespace, or punctuation.
if ! printf '%s' "$PROMPT" | grep -Eq '(^|[[:space:]])/deep-plan([[:space:]]|$|[,.;:!?])'; then
  exit 0
fi

# Marker file — durable signal for PreToolUse backstops.
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
STATE_DIR="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
MARKER_FILE="$STATE_DIR/${SESSION_ID:-default}.deep-plan-active"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$TS" > "$MARKER_FILE" 2>/dev/null || true

# Telemetry — fire-and-forget.
LOG_DIR="$HQ_ROOT/workspace/learnings"
mkdir -p "$LOG_DIR" 2>/dev/null || true
printf '{"ts":"%s","event":"deep-plan-routing-detected","session":"%s"}\n' \
  "$TS" "${SESSION_ID:-unknown}" \
  >> "$LOG_DIR/deep-plan-routing.jsonl" 2>/dev/null || true

# additionalContext — must be a single-line JSON value, so escape newlines.
cat <<'JSONOUT'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"<deep-plan-routing>\nDEEP-PLAN ROUTING DETECTED — the user's prompt contains `/deep-plan`.\n\nYou MUST load and execute the skill at `.claude/skills/deep-plan/SKILL.md`. That skill produces `companies/{co}/projects/{name}/prd.json` + `README.md` and registers an entry in `companies/{co}/board.json`. It hard-stops at Step 9 with `/handoff`.\n\nYou MUST NOT call `EnterPlanMode`. Built-in plan mode produces `~/.claude/plans/*.md` files; that is a different feature and is forbidden for `/deep-plan` invocations. PreToolUse hook `block-builtin-plan-mode-during-deep-plan.sh` will reject the call as a backstop, but do not rely on it — this rule is the primary contract.\n\nYou MUST NOT implement code in this session. The skill ends with `/handoff`. Implementation runs in a fresh session via `/run-project {name}` or `/execute-task {name}/US-001`. The only writes permitted are inside `companies/{co}/projects/{name}/` and `companies/{co}/board.json`. PreToolUse hook `block-plans-dir-during-deep-plan.sh` rejects any write to `~/.claude/plans/` for the rest of this session.\n\nIf auto mode is active, announce: \"Auto mode paused for /deep-plan — questionnaire requires user input.\" Then proceed question-by-question via `AskUserQuestion`.\n\nFull failure context: `core/policies/deep-plan-skill-routing.md`.\n</deep-plan-routing>"}}
JSONOUT

exit 0
