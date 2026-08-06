#!/bin/bash
# hq-hook-match: mcp__Claude_in_Chrome__*,mcp__playwright__*,mcp__Playwright__*
# 50-...--prefer-agent-browser.sh — PreToolUse warn/redirect (non-blocking).
#
# Enforces policy hq-prefer-agent-browser (soft) as a prompt-level nudge: when a
# session reaches for a competing INTERACTIVE browser MCP tool, remind it that the
# HQ default for browser automation is the agent-browser CLI. The tool still runs
# (exit 0) — this only injects additionalContext the model reads on the same turn.
#
# Matched tools (via the filename matcher segment, master-hook anchors it as
# ^(...)$ with `*`->`.*` and `,`->`|`):
#   mcp__Claude_in_Chrome__*  ·  mcp__playwright__*  ·  mcp__Playwright__*
#
# Deliberately NOT matched (complementary, not competing):
#   mcp__Claude_Preview__*  (app preview / `/run`)   ·   WebFetch (static fetch)
#
# Behavior:
#   - If agent-browser is not on PATH, stay silent (no usable alternative to
#     redirect to) → exit 0. The SessionStart presence hook handles "install it".
#   - Else emit a one-line, non-blocking reminder.
#
# Bypass: HQ_NO_AGENT_BROWSER_NUDGE=1 silences the nudge.
# Exit codes: always 0 (never blocks).
# Input: Claude Code PreToolUse JSON on stdin.
set -uo pipefail

[ "${HQ_NO_AGENT_BROWSER_NUDGE:-}" = "1" ] && exit 0

# Only worth redirecting if the preferred tool actually exists locally.
command -v agent-browser >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null || true)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || true)

# Build the message body without backticks ($-expansion only, no command subst).
read -r -d '' MSG <<EOF || true
<prefer-agent-browser>
HQ default for browser automation is the agent-browser CLI (policy hq-prefer-agent-browser). You called: ${tool:-a browser MCP tool}.

Unless this genuinely needs real-time visual interaction (or agent-browser can't do it), prefer agent-browser:
  agent-browser open <url>
  agent-browser snapshot -i      # @refs for interactive elements
  agent-browser fill @e1 "..." / click @e2 / get text body / screenshot --full
  agent-browser close

Vault logins (secret never enters model context):
  hq secrets exec --company <co> --only "SVC/API_KEY" -- bash -c 'TOK=\$(printenv "SVC/API_KEY"); agent-browser --headers "{\"Authorization\":\"Bearer \$TOK\"}" open https://...'

Non-blocking nudge — proceed with the MCP tool if it is genuinely the right call. Silence with HQ_NO_AGENT_BROWSER_NUDGE=1.
</prefer-agent-browser>
EOF

jq -nc --arg m "$MSG" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}' 2>/dev/null \
  || true
exit 0
