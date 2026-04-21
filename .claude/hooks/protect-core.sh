#!/bin/bash
# protect-core.sh — PreToolUse hook for Edit and Write
#
# Blocks edits to files in core.yaml locked list.
# Warns (but allows) edits to core.yaml reviewable list.
# Fails open (logs + allows) if core.yaml is missing or malformed.
#
# Environment:
#   HQ_BYPASS_CORE_PROTECT=1 — bypass all checks (used by /update-hq)
#
# Trigger: PreToolUse on Edit and Write
# Exit codes: 0 = allow, 2 = block

# Bypass mode — authorized updates only
if [[ "${HQ_BYPASS_CORE_PROTECT:-}" == "1" ]]; then
  exit 0
fi

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

# Canonicalize path to resolve any .. or . components
if command -v realpath >/dev/null 2>&1; then
  FILE_PATH="$(realpath -m "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")"
fi

# Locate HQ root via git
HQ_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$HQ_ROOT" ]]; then
  echo "WARNING: protect-core.sh could not determine HQ root (git rev-parse failed). Skipping check." >&2
  exit 0
fi

CORE_YAML="$HQ_ROOT/core.yaml"

# Fail open if core.yaml is missing
if [[ ! -f "$CORE_YAML" ]]; then
  echo "WARNING: protect-core.sh: core.yaml not found at $CORE_YAML. Skipping check." >&2
  exit 0
fi

# Check for yq
if ! which yq >/dev/null 2>&1; then
  echo "WARNING: protect-core.sh: yq not found. Skipping core protection check." >&2
  echo "  Install: brew install yq" >&2
  exit 0
fi

# Parse locked paths — fail open if yq fails
LOCKED_PATHS=$(yq eval '.rules.locked[]' "$CORE_YAML" 2>/dev/null) || {
  echo "WARNING: protect-core.sh: failed to parse core.yaml (malformed?). Skipping check." >&2
  exit 0
}

# Check locked paths
while IFS= read -r locked_path; do
  [[ -z "$locked_path" ]] && continue

  # Normalize: strip trailing slash from both sides for comparison
  locked_path_normalized="${locked_path%/}"
  file_path_normalized="${FILE_PATH%/}"
  locked_abs="${HQ_ROOT}/${locked_path_normalized}"

  # Check if file_path matches this locked entry (exact match or starts-with for directories)
  if [[ "$file_path_normalized" == "$locked_abs" ]] || [[ "$file_path_normalized" == "$locked_abs/"* ]]; then
    cat >&2 <<EOF
BLOCKED: Edit to locked core file is not allowed.
  File: $FILE_PATH
  Locked path: $locked_path

To bypass (authorized updates only): set HQ_BYPASS_CORE_PROTECT=1
EOF
    exit 2
  fi
done <<< "$LOCKED_PATHS"

# Parse reviewable paths — fail open if yq fails
REVIEWABLE_PATHS=$(yq eval '.rules.reviewable[]' "$CORE_YAML" 2>/dev/null) || {
  echo "WARNING: protect-core.sh: failed to parse reviewable paths from core.yaml. Skipping warning check." >&2
  exit 0
}

# Check reviewable paths
while IFS= read -r reviewable_path; do
  [[ -z "$reviewable_path" ]] && continue

  reviewable_path_normalized="${reviewable_path%/}"
  file_path_normalized="${FILE_PATH%/}"
  reviewable_abs="${HQ_ROOT}/${reviewable_path_normalized}"

  if [[ "$file_path_normalized" == "$reviewable_abs" ]] || [[ "$file_path_normalized" == "$reviewable_abs/"* ]]; then
    cat >&2 <<EOF
WARNING: Editing reviewable core path.
  File: $FILE_PATH
  Reviewable path: $reviewable_path
Edit allowed — proceed with care.
EOF
    exit 0
  fi
done <<< "$REVIEWABLE_PATHS"

# No match — open category, allow silently
exit 0
