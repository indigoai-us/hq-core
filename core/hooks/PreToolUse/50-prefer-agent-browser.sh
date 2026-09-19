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
#   - Always drain stdin first (early-exit SIGPIPE guard).
#   - Always warn about canvas-coordinate clicks and unscoped type, even when
#     agent-browser is missing — that fallback is how Google Docs edits get
#     mistyped into the document body.
#   - If agent-browser is on PATH, also redirect to the CLI workflow.
#   - If it is missing, tell the session to install it (SessionStart also
#     nudges) instead of treating Claude-in-Chrome coordinates as safe.
#
# Bypass: HQ_NO_AGENT_BROWSER_NUDGE=1 silences the nudge.
# Exit codes: always 0 (never blocks).
# Input: Claude Code PreToolUse JSON on stdin.
set -uo pipefail

# Drain stdin before any exit so a dispatcher writing the payload cannot die
# of SIGPIPE (hq-core 15.0.139 / hooks-drain-stdin-before-early-exit).
input=$(cat 2>/dev/null || true)

[ "${HQ_NO_AGENT_BROWSER_NUDGE:-}" = "1" ] && exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || true)

HAVE_AB=0
command -v agent-browser >/dev/null 2>&1 && HAVE_AB=1

# Build the message body without backticks ($-expansion only, no command subst).
if [ "$HAVE_AB" = "1" ]; then
read -r -d '' MSG <<EOF || true
<prefer-agent-browser>
HQ default for browser automation is the agent-browser CLI (policy hq-prefer-agent-browser). You called: ${tool:-a browser MCP tool}.

Unless this genuinely needs real-time visual interaction (or agent-browser can't do it), prefer agent-browser:
  agent-browser open <url>
  agent-browser snapshot -i      # @refs for interactive elements
  agent-browser fill @e1 "..." / click @e2 / get text body / screenshot --full
  agent-browser close

Canvas apps (Google Docs, Sheets, Slides, Figma): do not click from screenshot coordinates — they miss. Use snapshot/find refs for DOM dialogs and keyboard for canvas text. computer:type / type can silently write into the live document body. agent-browser cannot reuse a logged-in Chrome Google session; Google Workspace needs headed sign-in, then state save.

Vault logins (secret never enters model context):
  hq secrets exec --company <co> --only "SVC/API_KEY" -- bash -c 'TOK=\$(printenv "SVC/API_KEY"); agent-browser --headers "{\"Authorization\":\"Bearer \$TOK\"}" open https://...'

Non-blocking nudge — proceed with the MCP tool if it is genuinely the right call. Silence with HQ_NO_AGENT_BROWSER_NUDGE=1.
</prefer-agent-browser>
EOF
else
read -r -d '' MSG <<EOF || true
<prefer-agent-browser>
HQ default for browser automation is the agent-browser CLI (policy hq-prefer-agent-browser). You called: ${tool:-a browser MCP tool}. agent-browser is not on PATH — install with: npm install -g agent-browser && agent-browser install.

Until then, if you must use this MCP tool on a canvas app (Google Docs, Sheets, Slides, Figma): do not click from screenshot coordinates — they miss. Use find/DOM refs for real controls and keyboard for canvas text. computer:type / type can silently write into the live document body instead of a find box. agent-browser cannot reuse a logged-in Chrome Google session; Google Workspace needs headed sign-in after install.

Non-blocking nudge. Silence with HQ_NO_AGENT_BROWSER_NUDGE=1.
</prefer-agent-browser>
EOF
fi

jq -nc --arg m "$MSG" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}' 2>/dev/null \
  || true
exit 0
