#!/bin/bash
# protect-core.sh — PreToolUse hook for Edit and Write
#
# Blocks edits to files in core/core.yaml locked list.
# Warns (but allows) edits to core/core.yaml reviewable list.
# Fails open (logs + allows) if core/core.yaml is missing or malformed.
#
# Bypass: HQ_BYPASS_CORE_PROTECT must be set to "1" under "env" in
# .claude/settings.local.json. Inline env-var prefixes are NOT accepted.
#
# Trigger: PreToolUse on Edit and Write
# Exit codes: 0 = allow, 2 = block

set -uo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || true

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

if [[ "$FILE_PATH" != /* ]]; then
  FILE_PATH="$(pwd)/$FILE_PATH"
fi

if command -v python3 >/dev/null 2>&1; then
  FILE_PATH="$(python3 -c 'import os.path,sys; sys.stdout.write(os.path.normpath(sys.argv[1]))' "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")"
fi

HQ_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$HQ_ROOT" ]]; then
  echo "WARNING: protect-core.sh could not determine HQ root (git rev-parse failed). Skipping check." >&2
  exit 0
fi

CORE_YAML="$HQ_ROOT/core/core.yaml"
SETTINGS_LOCAL="$HQ_ROOT/.claude/settings.local.json"

if [[ ! -f "$CORE_YAML" ]]; then
  echo "WARNING: protect-core.sh: core/core.yaml not found. Skipping check." >&2
  exit 0
fi

if ! which yq >/dev/null 2>&1; then
  echo "WARNING: protect-core.sh: yq not found. Install: brew install yq" >&2
  exit 0
fi

# Bypass: must be declared in .claude/settings.local.json env section.
is_bypass_authorized() {
  [[ -f "$SETTINGS_LOCAL" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local val
  val=$(jq -r '.env.HQ_BYPASS_CORE_PROTECT // empty' "$SETTINGS_LOCAL" 2>/dev/null) || return 1
  [[ "$val" == "1" || "$val" == "true" ]] && return 0
  return 1
}

if is_bypass_authorized; then
  exit 0
fi

norm_path() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os.path,sys; sys.stdout.write(os.path.normpath(sys.argv[1]))' "$1" 2>/dev/null || echo "$1"
  else
    echo "$1"
  fi
}

# Check exclude list first — always allowed.
EXCLUDE_PATHS=$(yq eval '.rules.exclude[]' "$CORE_YAML" 2>/dev/null) || EXCLUDE_PATHS=""
while IFS= read -r exc_path; do
  [[ -z "$exc_path" ]] && continue
  exc_abs="$(norm_path "${HQ_ROOT}/${exc_path%/}")"
  if [[ "$FILE_PATH" == "$exc_abs" ]] || [[ "$FILE_PATH" == "$exc_abs/"* ]]; then
    exit 0
  fi
done <<< "$EXCLUDE_PATHS"

# Specific file redirects — give a helpful pointer before the generic block.
CLAUDE_MD_ABS="$(norm_path "${HQ_ROOT}/.claude/CLAUDE.md")"
SETTINGS_JSON_ABS="$(norm_path "${HQ_ROOT}/.claude/settings.json")"
if [[ "$FILE_PATH" == "$CLAUDE_MD_ABS" ]]; then
  cat >&2 <<MSG
BLOCKED: .claude/CLAUDE.md is the locked HQ charter.
  Edit personal/CLAUDE.md for your personal additions instead.
MSG
  exit 2
fi
if [[ "$FILE_PATH" == "$SETTINGS_JSON_ABS" ]]; then
  cat >&2 <<MSG
BLOCKED: .claude/settings.json is locked.
  Edit .claude/settings.local.json for local overrides instead.
MSG
  exit 2
fi

# Check locked paths.
LOCKED_PATHS=$(yq eval '.rules.locked[]' "$CORE_YAML" 2>/dev/null) || {
  echo "WARNING: protect-core.sh: failed to parse locked paths (malformed?). Skipping check." >&2
  exit 0
}

while IFS= read -r locked_path; do
  [[ -z "$locked_path" ]] && continue
  locked_abs="$(norm_path "${HQ_ROOT}/${locked_path%/}")"
  if [[ "$FILE_PATH" == "$locked_abs" ]] || [[ "$FILE_PATH" == "$locked_abs/"* ]]; then
    cat >&2 <<MSG
BLOCKED: Edit to locked path is not allowed.
  File: $FILE_PATH
  Locked: $locked_path

To bypass: set "HQ_BYPASS_CORE_PROTECT": "1" under "env" in .claude/settings.local.json
(inline env-var prefixes are not accepted).
MSG
    exit 2
  fi
done <<< "$LOCKED_PATHS"

# Check reviewable paths (warn, allow).
REVIEWABLE_PATHS=$(yq eval '.rules.reviewable[]' "$CORE_YAML" 2>/dev/null) || REVIEWABLE_PATHS=""
while IFS= read -r reviewable_path; do
  [[ -z "$reviewable_path" ]] && continue
  reviewable_abs="$(norm_path "${HQ_ROOT}/${reviewable_path%/}")"
  if [[ "$FILE_PATH" == "$reviewable_abs" ]] || [[ "$FILE_PATH" == "$reviewable_abs/"* ]]; then
    cat >&2 <<MSG
WARNING: Editing reviewable path.
  File: $FILE_PATH
  Reviewable: $reviewable_path
Edit allowed — proceed with care.
MSG
    exit 0
  fi
done <<< "$REVIEWABLE_PATHS"

exit 0
