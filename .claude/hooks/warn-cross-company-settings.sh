#!/bin/bash
# Warn when reading a company's settings/ while cwd suggests a different company context.
# PreToolUse hook for Read tool — warns but does not block (too many legitimate cross-reads).

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')

# Only check Read tool
if [ "$TOOL" != "Read" ]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Only check reads into companies/*/settings/
if ! echo "$FILE_PATH" | grep -qE 'companies/[^/]+/settings/'; then
  exit 0
fi

# Extract target company from file path
TARGET_CO=$(echo "$FILE_PATH" | sed -n 's|.*companies/\([^/]*\)/settings/.*|\1|p')
if [ -z "$TARGET_CO" ]; then
  exit 0
fi

# Try to infer active company from cwd
ACTIVE_CO=""

# Check if cwd is inside a company directory
if echo "$CWD" | grep -qE 'companies/[^/]+'; then
  ACTIVE_CO=$(echo "$CWD" | sed -n 's|.*companies/\([^/]*\).*|\1|p')
fi

# Check if cwd is inside a repo — look up which company owns it via manifest
if [ -z "$ACTIVE_CO" ] && echo "$CWD" | grep -qE 'repos/(private|public)/'; then
  REPO_PATH=$(echo "$CWD" | grep -oE 'repos/(private|public)/[^/]+')
  if [ -n "$REPO_PATH" ]; then
    HQ_ROOT=$(echo "$CWD" | sed 's|/repos/.*||')
    MANIFEST="$HQ_ROOT/companies/manifest.yaml"
    if [ -f "$MANIFEST" ]; then
      # Find which company block contains this repo path
      ACTIVE_CO=$(awk -v repo="$REPO_PATH" '
        /^[a-z]/ && /:/ { company = $0; gsub(/:.*/, "", company) }
        $0 ~ repo { print company; exit }
      ' "$MANIFEST")
    fi
  fi
fi

# If we can't determine active company, don't warn
if [ -z "$ACTIVE_CO" ]; then
  exit 0
fi

# Warn if mismatch
if [ "$TARGET_CO" != "$ACTIVE_CO" ]; then
  cat >&2 <<EOF
⚠️  CROSS-COMPANY SETTINGS ACCESS
Reading $TARGET_CO settings, but current context is $ACTIVE_CO.

Before proceeding, verify:
1. This is intentional (not a company routing mistake)
2. You checked manifest.yaml for correct company → service mapping
3. You loaded $TARGET_CO policies from companies/$TARGET_CO/policies/

If this is wrong, read companies/$ACTIVE_CO/settings/ instead.
EOF
  # Exit 0 = warn only, don't block
  exit 0
fi

exit 0
