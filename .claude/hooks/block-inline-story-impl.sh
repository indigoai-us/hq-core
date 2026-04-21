#!/bin/bash
# block-inline-story-impl.sh — PreToolUse hook for Edit and Write
#
# Warns when editing files inside repos/ outside of a run-project.sh sub-agent context.
# Does NOT block — warns only (exit 0 with stderr message).
#
# Environment:
#   HQ_EXECUTING_STORY=1 — set by run-project.sh when spawning claude -p sub-agents.
#                          Suppresses the warning (legitimate story execution context).
#
# Trigger: PreToolUse on Edit and Write

set -euo pipefail

# Read tool input from stdin
INPUT=$(cat)

# Extract file_path from the tool input JSON
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || true

# No file_path → nothing to check
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Resolve to absolute path if relative
if [[ "$FILE_PATH" != /* ]]; then
  FILE_PATH="$(pwd)/$FILE_PATH"
fi

# Check if path contains /repos/private/ or /repos/public/ (case-insensitive for macOS)
# macOS is case-insensitive but pwd may return different casing than hardcoded paths
FILE_PATH_LOWER=$(echo "$FILE_PATH" | tr '[:upper:]' '[:lower:]')
if [[ "$FILE_PATH_LOWER" != *"/repos/private/"* && "$FILE_PATH_LOWER" != *"/repos/public/"* ]]; then
  # Not a repo file — allow silently
  exit 0
fi

# If sub-agent context (run-project.sh story execution), allow silently
if [[ "${HQ_EXECUTING_STORY:-}" == "1" ]]; then
  exit 0
fi

# Repo file edited outside sub-agent context — warn
echo "WARNING: Direct repo edit outside run-project.sh context." >&2
echo "  File: $FILE_PATH" >&2
echo "  If executing a PRD project, use \`scripts/run-project.sh\`." >&2
echo "  If this is ad-hoc work (hotfix, exploration), ignore this warning." >&2
exit 0
