#!/bin/bash
# route-company-skill-creation.sh — PreToolUse hook for Write
#
# Hard-blocks direct writes to .claude/skills/{prefix}-{name}/ and
# .claude/commands/{prefix}-{name}.md when {prefix} resolves to a real company
# in companies/manifest.yaml.
#
# These mirror paths are owned by auto-mirror-company-skill.sh — agents must
# write to companies/{co}/skills/{name}/SKILL.md (or commands/{name}.md)
# instead, and let the PostToolUse hook create the symlink.
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

# Resolve prefix → company via manifest. If unknown prefix, this isn't a
# bridged path — let it through (some non-company skills like `hq-deploy` happen
# to look like prefix-name but don't match any manifest entry).
# NOTE: slurp the program into a variable via a standalone heredoc, then run it
# with `python3 -c`. A heredoc nested inside a `$( … )` substitution is
# mis-parsed as an unterminated quote by macOS system bash 3.2
# (policy indigo-hook-no-heredoc-in-command-substitution).
co_py=""
IFS= read -r -d '' co_py <<'PY' || true
import sys, yaml
prefix = sys.argv[1]
try:
    d = yaml.safe_load(open("companies/manifest.yaml"))
    for slug, meta in d.get("companies", {}).items():
        if meta.get("prefix") == prefix:
            print(slug)
            break
except Exception:
    pass
PY
CO=$(cd "$PROJECT_DIR" && python3 -c "$co_py" "$PREFIX" 2>/dev/null || true)

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
This is a mirror path for $CANONICAL.

Write to $CANONICAL instead — the auto-mirror PostToolUse hook will create
the symlink at .claude/skills/${PREFIX}-${NAME}/ (or .claude/commands/${PREFIX}-${NAME}.md) for you.

Override (rare, audited): set HQ_ALLOW_DIRECT_PREFIX_WRITE=1 to bypass this check.
MSG

exit 2
