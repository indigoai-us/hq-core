#!/bin/bash
# block-numbered-policy-sibling.sh — PreToolUse hook for Edit, Write, MultiEdit.
#
# Refuses to create a numbered sibling of an existing policy file, for example
# `<slug> 2.md` next to `<slug>.md` in a policies folder (feedback_732a6bfb).
# Such a file is a second copy of the policy: the injector and the linter both
# read it, so the rule is counted twice and edits to one copy are lost in the
# other. A policy change replaces `<slug>.md` in place.
#
# Only creation is refused. An existing numbered file can still be edited or
# removed, so cleanup of old siblings is not blocked.
#
# Exit codes: 0 = allow, 2 = block.
set -uo pipefail

INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)" || exit 0
[ -n "$FILE_PATH" ] || exit 0

case "$FILE_PATH" in
  */policies/*.md) ;;
  *) exit 0 ;;
esac

dir="${FILE_PATH%/*}"
base="${FILE_PATH##*/}"
# Only the policies folder itself, not a deeper folder such as _archive/.
case "$dir" in */policies) ;; *) exit 0 ;; esac

if [[ "$base" =~ ^(.+)\ ([0-9]+)\.md$ ]]; then
  original="${BASH_REMATCH[1]}.md"
  [ -e "$FILE_PATH" ] && exit 0
  if [ -f "$dir/$original" ]; then
    printf "BLOCKED: '%s' would be a numbered copy of the existing policy '%s' in %s.\n\n" "$base" "$original" "$dir" >&2
    printf "Two copies of one policy are both injected and linted, and edits to one are\n" >&2
    printf "lost in the other. Change the policy by replacing '%s' in place (Edit it,\n" "$original" >&2
    printf "or Write the full new content to '%s'). If '%s' is a different policy,\n" "$original" "$base" >&2
    printf "give it its own slug.\n" >&2
    exit 2
  fi
fi
exit 0
