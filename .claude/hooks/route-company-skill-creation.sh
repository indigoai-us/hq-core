#!/bin/bash
# route-company-skill-creation.sh — PreToolUse hook for Write/Edit/MultiEdit
#
# Hard-blocks two identity-bypassing paths:
#   1. creating/editing an unstamped canonical company SKILL.md;
#   2. writing a generated company skill/command mirror directly.
#
# Company skills must reserve an immutable skill_uid through `hq skill create`
# before an agent authors them. Generated runtime wrappers are owned by reindex.
#
# Override: HQ_ALLOW_DIRECT_PREFIX_WRITE=1 lets the write through (rare).
#
# Trigger: PreToolUse on Write

set -euo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || true

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

if [[ "${HQ_ALLOW_DIRECT_PREFIX_WRITE:-}" == "1" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

if [[ "$FILE_PATH" == /* ]]; then
  case "$FILE_PATH" in
    "$PROJECT_DIR"/*) REL="${FILE_PATH#$PROJECT_DIR/}" ;;
    *) exit 0 ;;
  esac
else
  REL="$FILE_PATH"
fi

# Canonical company skill. An existing, server-stamped file is safe to edit in
# place. A new or legacy unstamped file must be registered first so normal sync
# can never publish a skill without an immutable identity.
if [[ "$REL" =~ ^companies/([a-z0-9][a-z0-9-]*)/skills/([a-z0-9][a-z0-9-]*)/SKILL\.md$ ]]; then
  CO="${BASH_REMATCH[1]}"
  NAME="${BASH_REMATCH[2]}"
  CANONICAL="$PROJECT_DIR/$REL"
  SKILL_UID=""
  if [[ -f "$CANONICAL" ]]; then
    SKILL_UID="$(awk '
      NR == 1 && $0 ~ /^---\r?$/ { in_frontmatter = 1; next }
      in_frontmatter && $0 ~ /^---\r?$/ { exit }
      in_frontmatter && $0 ~ /^[[:space:]]*skill_uid:[[:space:]]*/ {
        line = $0
        sub(/^[[:space:]]*skill_uid:[[:space:]]*/, "", line)
        sub(/[[:space:]\r]*$/, "", line)
        print line
        exit
      }
    ' "$CANONICAL" 2>/dev/null || true)"
    case "$SKILL_UID" in
      \"*\") SKILL_UID="${SKILL_UID#\"}"; SKILL_UID="${SKILL_UID%\"}" ;;
      \'*\') SKILL_UID="${SKILL_UID#\'}"; SKILL_UID="${SKILL_UID%\'}" ;;
    esac
  fi

  if [[ "$SKILL_UID" =~ ^skl_[A-Za-z0-9]+$ ]]; then
    exit 0
  fi

  cat >&2 <<MSG
BLOCKED: $REL does not have a registered skill_uid.

Reserve and stamp the company skill before editing it:
  hq skill --company $CO create $NAME --no-sync

Then edit the stamped canonical file and finish with:
  hq skill --company $CO create $NAME

This keeps creation, FILE_ACL policy, reindexing, and sync on one authoritative path.
MSG
  exit 2
fi

# Match three mirror shapes:
#   .claude/skills/{prefix}-{name}/...
#   .claude/skills/{prefix}-{name}.md
#   .claude/commands/{prefix}-{name}.md
PREFIX=""
NAME=""

if [[ "$REL" =~ ^\.claude/skills/([a-z0-9]{2,4})-([a-z0-9_-]+)(/.*|\.md)?$ ]]; then
  PREFIX="${BASH_REMATCH[1]}"
  NAME="${BASH_REMATCH[2]}"
elif [[ "$REL" =~ ^\.claude/commands/([a-z0-9]{2,4})-([a-z0-9_-]+)\.md$ ]]; then
  PREFIX="${BASH_REMATCH[1]}"
  NAME="${BASH_REMATCH[2]}"
else
  exit 0
fi

# Resolve prefix → company via manifest (yq, same engine as the registry
# hooks). If unknown prefix — or yq is unavailable — this isn't a bridged
# path; let it through (some non-company skills like `hq-deploy` happen to
# look like prefix-name but don't match any manifest entry).
CO=$(cd "$PROJECT_DIR" && yq -r ".companies | to_entries[] | select(.value.prefix == \"$PREFIX\") | .key" companies/manifest.yaml 2>/dev/null | head -1 || true)
[ "$CO" = "null" ] && CO=""

if [[ -z "$CO" ]]; then
  exit 0
fi

# Decide whether this looks like a skill or command, for the redirect message.
if [[ "$REL" == .claude/commands/* ]]; then
  CANONICAL="companies/$CO/commands/$NAME.md"
else
  CANONICAL="companies/$CO/skills/$NAME/SKILL.md"
fi

cat >&2 <<MSG
BLOCKED: Direct write to $REL is not allowed.
This is a generated runtime path for $CANONICAL.

For a new company skill, run:
  hq skill --company $CO create $NAME --no-sync

Then edit $CANONICAL and run the create command again to reindex and sync it.
Generated `.claude/skills/` wrappers are owned by HQ reindexing.

Override (rare, audited): set HQ_ALLOW_DIRECT_PREFIX_WRITE=1 to bypass this check.
MSG

exit 2
