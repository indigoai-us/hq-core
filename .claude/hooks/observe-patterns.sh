#!/bin/bash
# Stop hook: analyze session patterns and auto-suggest /learn candidates.
# Fires when a session ends to extract reusable patterns from git history and session state.
# Output nudge message suggesting /learn invocation for high-confidence patterns.

set -euo pipefail

# Resolve the active HQ root regardless of install path or session cwd:
# CLAUDE_PROJECT_DIR (set by Claude Code) → HQ_ROOT env → the hook's own
# location (always <HQ>/.claude/hooks/, matching master-hook.sh/reindex.sh) →
# legacy default. Never hardcode ~/Documents/HQ as the sole source.
HQ="${CLAUDE_PROJECT_DIR:-${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)}}"
HQ="${HQ:-${HOME}/Documents/HQ}"
INPUT=$(cat)

# Ensure learnings directory exists
mkdir -p "$HQ/workspace/learnings"

# Get current state
cd "$HQ"
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
TIMESTAMP_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Detect project context (from cwd or git toplevel basename)
PROJECT_CONTEXT="${GIT_BRANCH}"
if [ "$GIT_BRANCH" = "HEAD" ] || [ "$GIT_BRANCH" = "main" ]; then
  PROJECT_CONTEXT="hq"
fi

# Initialize observations array
observations=()

# Analyze git log for patterns (last 50 commits in this session are likely recent)
GIT_LOG=$(git log --oneline -50 2>/dev/null || echo "")

# Pattern 1: back-pressure-retry detection (fixup commits indicate retry loop)
if echo "$GIT_LOG" | grep -qiE '(fixup|amend|rebase|retry|fix.*previous)'; then
  IFS= read -r -d '' pattern1 <<'PATTERN1' || true
{
  "pattern_type": "back-pressure-retry",
  "confidence": 0.8,
  "description": "Git log shows fixup/amend/retry commits, indicating back-pressure correction cycle",
  "severity": "high",
  "evidence": "fixup/amend commits in recent history",
  "recommendation": "Extract pattern about what caused retry and how to prevent it next time"
}
PATTERN1
  observations+=("$pattern1")
fi

# Pattern 2: repeated tool failure detection (check for error/fail keywords)
if echo "$GIT_LOG" | grep -qiE '(fix.*error|resolve.*bug|handle.*fail)'; then
  IFS= read -r -d '' pattern2 <<'PATTERN2' || true
{
  "pattern_type": "repeated-tool-failure",
  "confidence": 0.6,
  "description": "Git log shows error/bug fixes, suggesting repeated failures were encountered",
  "severity": "medium",
  "evidence": "fix/error/bug keywords in commits",
  "recommendation": "Identify what tool/process failed repeatedly and capture prevention pattern"
}
PATTERN2
  observations+=("$pattern2")
fi

# Pattern 3: workflow improvement detection (new hooks, commands, scripts created)
if echo "$GIT_LOG" | grep -qiE '(hook|command|script|workflow|automation)'; then
  IFS= read -r -d '' pattern3 <<'PATTERN3' || true
{
  "pattern_type": "workflow-improvement",
  "confidence": 0.6,
  "description": "Session created or modified hooks/commands/scripts, improving automation",
  "severity": "medium",
  "evidence": "commits mentioning hooks, commands, or workflow",
  "recommendation": "Document the workflow improvement pattern for reuse"
}
PATTERN3
  observations+=("$pattern3")
fi

# Pattern 4: novel pattern detection (check for new file types or integrations)
if echo "$GIT_LOG" | grep -qiE '(add|new|integrate|extend|support)'; then
  IFS= read -r -d '' pattern4 <<'PATTERN4' || true
{
  "pattern_type": "novel-pattern",
  "confidence": 0.4,
  "description": "Session added new features or integrations",
  "severity": "low",
  "evidence": "add/new/integrate keywords in commits",
  "recommendation": "Low confidence: worth noting but verify pattern utility before capture"
}
PATTERN4
  observations+=("$pattern4")
fi

# Only generate output if observations were found
if [ ${#observations[@]} -eq 0 ]; then
  # No patterns detected; exit silently
  exit 0
fi

# Write observations to temp file for /learn to read
OBSERVATIONS_FILE="$HQ/workspace/learnings/.observe-patterns-latest.json"
cat > "$OBSERVATIONS_FILE" <<EOF
{
  "metadata": {
    "created_at": "${TIMESTAMP_ISO}",
    "session_end_timestamp": "${TIMESTAMP}",
    "git_branch": "${GIT_BRANCH}",
    "git_commit": "${GIT_SHA}",
    "project_context": "${PROJECT_CONTEXT}"
  },
  "observations": [
$(printf '%s,\n' "${observations[@]}" | sed '$s/,$//')
  ]
}
EOF

# Output nudge message
cat <<EOF
PATTERN LEARNING OPPORTUNITY DETECTED.

Session patterns have been analyzed and stored at:
  workspace/learnings/.observe-patterns-latest.json

Consider running /learn to extract high-confidence patterns:
  /learn

Or review observations manually:
  cat workspace/learnings/.observe-patterns-latest.json | jq .observations

Note: /learn will process these automatically or skip if patterns already exist (dedup).
EOF
