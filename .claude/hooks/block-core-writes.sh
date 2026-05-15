#!/bin/bash
# block-core-writes.sh — PreToolUse hook for Edit, Write, MultiEdit.
#
# Blocks any write inside core/. Authoring belongs in personal/; master-sync
# mirrors personal/<type>/<entry> into core/<type>/<entry> as symlinks. Writes
# that resolve through such a symlink (i.e. the path under core/ is itself a
# symlink, or sits under one) are allowed because they ultimately land in
# personal/.
#
# Environment:
#   HQ_BYPASS_CORE_PROTECT=1 — bypass (used by authorized core updates)
#
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

if [[ "${HQ_BYPASS_CORE_PROTECT:-}" == "1" ]]; then
  cat >/dev/null
  exit 0
fi

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || true
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

if [[ "$FILE_PATH" != /* ]]; then
  FILE_PATH="$PROJECT_DIR/$FILE_PATH"
fi

# Lexically normalize so spellings like `./core/x`, `core/./x`, `core//x`, or
# `core/../core/x` cannot bypass the prefix check below. We intentionally do
# NOT resolve symlinks here — the probe loop further down relies on seeing
# symlinks in the path so writes routed through master-sync mirrors stay
# allowed. macOS `realpath` lacks `-m`, so use python3's lexical normpath,
# which is universal. Falls back to the raw path if python3 is unavailable.
if command -v python3 >/dev/null 2>&1; then
  FILE_PATH="$(python3 -c 'import os.path,sys; sys.stdout.write(os.path.normpath(sys.argv[1]))' "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")"
  PROJECT_DIR="$(python3 -c 'import os.path,sys; sys.stdout.write(os.path.normpath(sys.argv[1]))' "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")"
fi

CORE_DIR="$PROJECT_DIR/core"

# Only concerned with paths under core/.
case "$FILE_PATH" in
  "$CORE_DIR"|"$CORE_DIR"/*) ;;
  *) exit 0 ;;
esac

# Walk from the target path upward to core/. If any existing component along
# the way is a symlink, the write actually lands in the symlink's target
# (personal/), so allow it.
probe="$FILE_PATH"
while [[ "$probe" == "$CORE_DIR"/* ]]; do
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
BLOCKED: direct writes to core/ are not allowed.
  File: $REL

core/ is a generated mirror. Edit the corresponding file under personal/ and
master-sync will symlink it into core/ automatically. For paths under
core/{knowledge,policies,workers,settings}/<name>, put your change at
personal/<type>/<name>/... instead.

To bypass (authorized core updates only): set HQ_BYPASS_CORE_PROTECT=1

If this block is wrong or surprising, report it with /hq-bug (wraps
\`hq feedback\`).
EOF
exit 2
