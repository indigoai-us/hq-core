#!/bin/bash
# 50-agent-browser-presence-check.sh — SessionStart presence nudge.
#
# HQ prefers the agent-browser CLI for browser automation (policy
# hq-prefer-agent-browser). The PreToolUse redirect hook stays silent when
# agent-browser isn't installed (nothing to redirect to). This hook closes that
# gap: if agent-browser is missing, surface a one-line install reminder at
# session start. When installed (the common case) it exits immediately.
#
# Bypass: HQ_NO_AGENT_BROWSER_NUDGE=1 silences the nudge.
# Exit codes: always 0.
set -uo pipefail

[ "${HQ_NO_AGENT_BROWSER_NUDGE:-}" = "1" ] && exit 0
command -v agent-browser >/dev/null 2>&1 && exit 0

jq -nc '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:"agent-browser (HQ default for browser automation — policy hq-prefer-agent-browser) is not on PATH. Install once with: brew install agent-browser && agent-browser install. Until then, browser/QA tasks fall back to MCP tools. Silence with HQ_NO_AGENT_BROWSER_NUDGE=1."}}' 2>/dev/null || true
exit 0
