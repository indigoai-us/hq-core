#!/bin/bash
# hq-grok-hook-adapter.sh — route Grok PreToolUse hooks through HQ's existing
# .claude/hooks gate, so HQ's guardrails enforce for Grok exactly as for Claude.
#
# Grok differs from Claude in two ways this adapter bridges:
#   1. Payload shape: Grok sends camelCase (toolName / toolInput) and its own tool
#      names (run_terminal_command, search_replace, write, read_file). HQ's hooks
#      expect Claude-shaped snake_case (tool_name / tool_input.command|file_path)
#      with Claude tool names (Bash/Write/Edit/Read).
#   2. Block protocol: Grok blocks a tool call when a PreToolUse hook prints
#      {"decision":"deny","reason":...} on stdout (exit 2 also denies). HQ's hooks
#      signal a block via non-zero exit + a human message on stderr.
#
# This adapter normalizes the payload, runs the canonical HQ block hooks via the
# shared hook-gate, and on the first block emits Grok's deny JSON carrying the
# hook's message. Requires the project to be trusted (see .grok/README.md).
set -uo pipefail

INPUT_RAW="$(cat 2>/dev/null || echo '{}')"
jget() { printf '%s' "$INPUT_RAW" | jq -r "$1" 2>/dev/null || true; }

EVENT="$(jget '.hookEventName // .hook_event_name // empty')"
GTOOL="$(jget '.toolName // .tool_name // empty')"

# Resolve HQ root from this adapter's own location (immune to cwd): the adapter
# always lives at <HQ_ROOT>/.grok/hooks/hq-grok-hook-adapter.sh.
self_src="${BASH_SOURCE[0]:-$0}"
self_dir="$(cd "$(dirname "$self_src")" 2>/dev/null && pwd -P || true)"
HQ_ROOT=""
if [ -n "$self_dir" ]; then
  cand="$(cd "$self_dir/../.." 2>/dev/null && pwd -P || true)"
  [ -n "$cand" ] && [ -x "$cand/.claude/hooks/hook-gate.sh" ] && HQ_ROOT="$cand"
fi
[ -z "$HQ_ROOT" ] && HQ_ROOT="${CLAUDE_PROJECT_DIR:-${GROK_WORKSPACE_ROOT:-$(pwd)}}"
GATE="$HQ_ROOT/.claude/hooks/hook-gate.sh"
HOOK_DIR="$HQ_ROOT/.claude/hooks"
# Fail-open to allow if HQ isn't resolvable (never wedge a non-HQ project).
[ -x "$GATE" ] || { echo '{"decision":"allow"}'; exit 0; }

# Map Grok's tool name to the Claude tool name HQ hooks key on.
# Grok 0.2.56 emits Shell / StrReplace / Read / Write (NOT the published
# run_terminal_command / search_replace alias names). Cover both so the adapter
# is robust to tool-name drift; the match-all matcher in hq-grok.json makes this
# case the single source of truth.
case "$GTOOL" in
  run_terminal_command|Shell|Bash)                            CTOOL=Bash ;;
  search_replace|StrReplace|write|edit|Edit|Write|MultiEdit)  CTOOL=Write ;;
  read_file|Read)                                             CTOOL=Read ;;
  *)                                                          CTOOL="$GTOOL" ;;
esac

CMD="$(jget '.toolInput.command // .tool_input.command // empty')"
FP="$(jget '.toolInput.file_path // .toolInput.path // .tool_input.file_path // .tool_input.path // empty')"
CLAUDE_JSON="$(jq -n --arg t "$CTOOL" --arg c "$CMD" --arg f "$FP" '
  {tool_name:$t, tool_input: ( {}
    + (if $c != "" then {command:$c} else {} end)
    + (if $f != "" then {file_path:$f} else {} end) )}' 2>/dev/null)"

deny() { jq -n --arg r "$1" '{decision:"deny", reason:$r}'; exit 2; }

run_block() { # <hook-id> <hook-script>
  [ -x "$2" ] || return 0
  local err st
  err="$(printf '%s' "$CLAUDE_JSON" | HQ_ROOT="$HQ_ROOT" CLAUDE_PROJECT_DIR="$HQ_ROOT" "$GATE" "$1" "$2" 2>&1 1>/dev/null)"
  st=$?
  if [ "$st" -ne 0 ]; then
    deny "$(printf '%s' "${err:-Blocked by HQ guard: $1}" | head -c 1200)"
  fi
}

case "$EVENT" in
  PreToolUse|pre_tool_use)
    case "$CTOOL" in
      Bash)
        run_block detect-secrets              "$HOOK_DIR/detect-secrets.sh"
        run_block block-core-writes-bash      "$HOOK_DIR/block-core-writes-bash.sh"
        run_block block-hq-root-git-mutation  "$HOOK_DIR/block-hq-root-git-mutation.sh"
        run_block block-unsafe-package-install "$HOOK_DIR/block-unsafe-package-install.sh"
        ;;
      Write|Edit)
        run_block protect-core                "$HOOK_DIR/protect-core.sh"
        run_block block-core-writes           "$HOOK_DIR/block-core-writes.sh"
        ;;
    esac
    echo '{"decision":"allow"}'
    ;;
  *)
    : ;;  # passive events: nothing to enforce
esac
exit 0
