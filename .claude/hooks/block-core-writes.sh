#!/bin/bash
# block-core-writes.sh — PreToolUse hook for Edit, Write, MultiEdit.
#
# Blocks any write inside core/ or .claude/. Authoring belongs in personal/;
# reindex mirrors personal/<type>/<entry> into core/<type>/<entry> as symlinks.
# Writes that resolve through such a symlink are allowed (they land in personal/).
#
# Exception: .claude/settings.local.json is always allowed.
#
# Bypass: HQ_BYPASS_CORE_PROTECT="1" under "env" in .claude/settings.local.json.
# Enabling it disables protection for every later write, so an agent must NEVER
# set it autonomously — the block message tells it to ask the user first.
# Inline env-var prefixes are NOT accepted.
#
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || true
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

if [[ "$FILE_PATH" != /* ]]; then
  FILE_PATH="$PROJECT_DIR/$FILE_PATH"
fi

if command -v python3 >/dev/null 2>&1; then
  FILE_PATH="$(python3 -c 'import os.path,sys; sys.stdout.write(os.path.normpath(sys.argv[1]))' "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")"
  PROJECT_DIR="$(python3 -c 'import os.path,sys; sys.stdout.write(os.path.normpath(sys.argv[1]))' "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")"
fi

CORE_DIR="$PROJECT_DIR/core"
CLAUDE_DIR="$PROJECT_DIR/.claude"
AGENTS_DIR="$PROJECT_DIR/.agents"
CODEX_DIR="$PROJECT_DIR/.codex"
OBSIDIAN_DIR="$PROJECT_DIR/.obsidian"
AGENTS_MD="$PROJECT_DIR/AGENTS.md"
SETTINGS_LOCAL="$PROJECT_DIR/.claude/settings.local.json"

# Only concerned with protected paths.
case "$FILE_PATH" in
  "$CORE_DIR"|"$CORE_DIR"/*|\
  "$CLAUDE_DIR"|"$CLAUDE_DIR"/*|\
  "$AGENTS_DIR"|"$AGENTS_DIR"/*|\
  "$CODEX_DIR"|"$CODEX_DIR"/*|\
  "$OBSIDIAN_DIR"|"$OBSIDIAN_DIR"/*|\
  "$AGENTS_MD") ;;
  *) exit 0 ;;
esac

# Exception: .claude/settings.local.json is always allowed.
if [[ "$FILE_PATH" == "$SETTINGS_LOCAL" ]]; then
  exit 0
fi

# Bypass: must be declared in .claude/settings.local.json env section.
# NOTE: agents must ask the user before enabling this (see block message).
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

# Specific file redirects — give a helpful pointer before the generic block.
if [[ "$FILE_PATH" == "$PROJECT_DIR/.claude/CLAUDE.md" ]]; then
  cat >&2 <<MSG
BLOCKED: .claude/CLAUDE.md is the locked HQ charter.
  Edit personal/CLAUDE.md for your personal additions instead.
MSG
  exit 2
fi
if [[ "$FILE_PATH" == "$PROJECT_DIR/.claude/settings.json" ]]; then
  cat >&2 <<MSG
BLOCKED: .claude/settings.json is locked.
  Edit .claude/settings.local.json for local overrides instead.
MSG
  exit 2
fi

# Walk upward from target. If any existing component is a symlink,
# the write lands in personal/ (reindex mirror) — allow it.
probe="$FILE_PATH"
while [[ "$probe" == "$CORE_DIR"/* || "$probe" == "$CLAUDE_DIR"/* || \
         "$probe" == "$AGENTS_DIR"/* || "$probe" == "$CODEX_DIR"/* || \
         "$probe" == "$OBSIDIAN_DIR"/* ]]; do
  if [[ -L "$probe" ]]; then
    exit 0
  fi
  parent="$(dirname "$probe")"
  if [[ "$parent" == "$probe" ]]; then
    break
  fi
  probe="$parent"
done

REL="${FILE_PATH#$PROJECT_DIR/}"

cat >&2 <<EOF
BLOCKED: direct writes to protected scaffold paths are not allowed.
  File: $REL

Protected: core/, .claude/, .agents/, .codex/, .obsidian/, AGENTS.md
Exception: .claude/settings.local.json is always writable.

Preferred fix: author the content under personal/ and reindex will symlink it
into core/ — no bypass needed.

A bypass exists, but DO NOT enable it on your own. Setting
"HQ_BYPASS_CORE_PROTECT": "1" under "env" in .claude/settings.local.json turns
OFF this protection for EVERY later write, so it requires the user's explicit
approval. Ask the user to confirm first; only with their go-ahead set the flag
(and offer to turn it back off when done). Inline env-var prefixes are not
accepted.

If this block is wrong or surprising, report it with /hq-bug.
EOF
exit 2
