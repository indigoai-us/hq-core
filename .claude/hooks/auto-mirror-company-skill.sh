#!/bin/bash
# auto-mirror-company-skill.sh — PostToolUse hook for Write
#
# When a top-level skill or command file is written under
# companies/{co}/skills/ or companies/{co}/commands/, create a relative
# symlink at .claude/skills/{prefix}-{name}/ or .claude/commands/{prefix}-{name}.md
# so the artifact is callable as a root-level slash command.
#
# Worker-nested skills (companies/{co}/workers/{worker}/skills/) are intentionally
# NOT mirrored — they keep their existing /run {worker} {skill} access path.
#
# Idempotent: matching symlink → no-op; mismatching symlink → log + skip; missing
# manifest prefix → log + skip (prefix is auto-seeded by /newcompany; lazy users
# get a stderr nudge rather than a hard failure).
#
# Trigger: PostToolUse on Write

set -euo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || true

if [[ -z "$FILE_PATH" ]]; then
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

KIND=""
CO=""
NAME=""
SOURCE_REL=""

if [[ "$REL" =~ ^companies/([^/]+)/skills/([^/]+)/SKILL\.md$ ]]; then
  CO="${BASH_REMATCH[1]}"
  NAME="${BASH_REMATCH[2]}"
  KIND="skill-dir"
  SOURCE_REL="companies/$CO/skills/$NAME"
elif [[ "$REL" =~ ^companies/([^/]+)/skills/([^/]+)\.md$ ]]; then
  CO="${BASH_REMATCH[1]}"
  NAME="${BASH_REMATCH[2]}"
  KIND="skill-flat"
  SOURCE_REL="companies/$CO/skills/$NAME.md"
elif [[ "$REL" =~ ^companies/([^/]+)/commands/([^/]+)\.md$ ]]; then
  CO="${BASH_REMATCH[1]}"
  NAME="${BASH_REMATCH[2]}"
  KIND="command"
  SOURCE_REL="companies/$CO/commands/$NAME.md"
else
  exit 0
fi

PREFIX=$(
  cd "$PROJECT_DIR" && python3 - "$CO" <<'PY' 2>/dev/null || true
import sys, yaml
co = sys.argv[1]
try:
    d = yaml.safe_load(open("companies/manifest.yaml"))
    p = d.get("companies", {}).get(co, {}).get("prefix")
    if p:
        print(p)
except Exception:
    pass
PY
)

if [[ -z "$PREFIX" ]]; then
  echo "auto-mirror: no prefix in manifest for company '$CO' — skipping mirror for $REL" >&2
  exit 0
fi

case "$KIND" in
  skill-dir)
    MIRROR_REL=".claude/skills/${PREFIX}-${NAME}"
    TARGET="../../$SOURCE_REL"
    ;;
  skill-flat)
    MIRROR_REL=".claude/skills/${PREFIX}-${NAME}.md"
    TARGET="../../$SOURCE_REL"
    ;;
  command)
    MIRROR_REL=".claude/commands/${PREFIX}-${NAME}.md"
    TARGET="../../$SOURCE_REL"
    ;;
esac

MIRROR_ABS="$PROJECT_DIR/$MIRROR_REL"

if [[ -L "$MIRROR_ABS" ]]; then
  CURRENT=$(readlink "$MIRROR_ABS")
  if [[ "$CURRENT" == "$TARGET" ]]; then
    exit 0
  fi
  echo "auto-mirror: $MIRROR_REL exists but points to '$CURRENT' (expected '$TARGET') — leaving alone" >&2
  exit 0
fi

if [[ -e "$MIRROR_ABS" ]]; then
  echo "auto-mirror: $MIRROR_REL already exists as a regular file/dir — refusing to overwrite" >&2
  exit 0
fi

mkdir -p "$(dirname "$MIRROR_ABS")"
ln -s "$TARGET" "$MIRROR_ABS"
echo "auto-mirror: linked $MIRROR_REL → $TARGET" >&2
exit 0
