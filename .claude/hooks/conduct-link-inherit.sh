#!/usr/bin/env bash
# Sessions started by a linked session join the same conduct link.
#
# A conducted child that starts its own session (start_session) used to leave
# that session off the link: it never reported, and a decision it asked for sat
# in its own window where the conductor could not see it.
#
#   PreToolUse (start_session, in a session on a conduct link): records an
#     invite with the whole brief and the parent's company set.
#   UserPromptSubmit (in a session not yet on a link): when the prompt contains
#     exactly one invite's whole brief, that invite becomes the session's
#     pending claim.
#   UserPromptSubmit and PostToolUse: once the session's company set is bound
#     and sits inside the invite's, joins the link as <parent>-<name> and adds
#     the standing rules to the context. Failures are logged to
#     workspace/logs/conduct-link-inherit.log.
#
# The logic is core/scripts/lib/conduct-link-inherit.mjs. Never blocks and
# never changes the tool input; every failure exits 0 with no output.
set -uo pipefail

event="${1:-}"
case "$event" in
  PreToolUse|UserPromptSubmit|PostToolUse) ;;
  *) exit 0 ;;
esac
command -v node >/dev/null 2>&1 || exit 0
root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)}"
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/core/scripts/lib/conduct-link-inherit.mjs"
[ -f "$lib" ] || exit 0
node "$lib" "$event" "$root" 2>/dev/null || true
exit 0
