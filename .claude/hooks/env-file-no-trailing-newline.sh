#!/usr/bin/env bash
# PreToolUse hook: block Write/Edit to .env* files whose content contains a
# KEY="..." quoted value with a literal \n or trailing whitespace inside the
# quotes. Prevents the April 2026 Maggie 401 class of bug where a pasted
# `API_SECRET="…\n"` silently broke byte-exact bearer-token compares.
#
# Policy: core/policies/env-file-no-trailing-newline.md
# Exit codes: 0 = allow, 2 = hard block (exit 2 stops the tool call).

set -euo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')

# Only inspect Write and Edit
if [ "$TOOL" != "Write" ] && [ "$TOOL" != "Edit" ]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only .env* files — match basename against a leading-dot "env" prefix.
# Case-insensitive (".ENV" is the same file on a case-insensitive filesystem),
# and a symlink is judged by its target too, so a link named "notes" that
# points at ".env" is still checked.
is_env_name() {
  case "$(basename "$1" | tr '[:upper:]' '[:lower:]')" in
    .env|.env.*|*.env|*.env.*) return 0 ;;
  esac
  return 1
}
RESOLVED_PATH="$FILE_PATH"
case "$RESOLVED_PATH" in
  /*) ;;
  *)
    CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
    [ -n "$CWD" ] && RESOLVED_PATH="$CWD/$RESOLVED_PATH"
    ;;
esac
RESOLVED_PATH=$(realpath "$RESOLVED_PATH" 2>/dev/null || printf '%s' "$RESOLVED_PATH")
if ! is_env_name "$FILE_PATH" && ! is_env_name "$RESOLVED_PATH"; then
  exit 0
fi

# Content to inspect: Write → .tool_input.content; Edit → .tool_input.new_string
CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // empty')
if [ -z "$CONTENT" ]; then
  exit 0
fi

# Bad patterns, per-line:
#   KEY="…\n…"      — literal two-char \n inside quotes
#   KEY="… "        — trailing space(s)/tab(s) inside quotes
#   KEY="…<CR>"     — trailing CR inside quotes
# We test each non-comment line; the KEY regex matches KEY or KEY_NAME style.
VIOLATION=$(printf '%s\n' "$CONTENT" | awk '
  # skip blank lines and comments
  /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
  # only look at KEY="..." lines
  /^[[:space:]]*[A-Z_][A-Z0-9_]*=".*"[[:space:]]*$/ {
    # literal backslash-n inside quotes
    if ($0 ~ /=".*\\n.*"[[:space:]]*$/) { print "literal_backslash_n"; exit }
    # trailing whitespace or CR inside closing quote: quote preceded by space/tab/CR
    if ($0 ~ /=".*[ \t\r]"[[:space:]]*$/) { print "trailing_whitespace"; exit }
  }
')

if [ -n "$VIOLATION" ]; then
  cat >&2 <<EOF
BLOCKED: $FILE_PATH contains an env line whose quoted value has $VIOLATION.

This class of contamination caused the April 2026 Maggie 401 incident — a
server read API_SECRET="…\\n" while clients sent a clean Bearer header, and
the byte-exact compare 401'd every request.

Fix: remove the trailing whitespace / \\n from inside the quotes. Either

  KEY=value
  KEY="value"     # no trailing whitespace before the closing quote

Policy: core/policies/env-file-no-trailing-newline.md
EOF
  exit 2
fi

exit 0
