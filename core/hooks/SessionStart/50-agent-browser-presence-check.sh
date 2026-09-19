#!/bin/bash
# 50-agent-browser-presence-check.sh — SessionStart presence nudge.
#
# HQ prefers the agent-browser CLI for browser automation (policy
# hq-prefer-agent-browser). If agent-browser is missing, surface a one-line
# install reminder at session start (and warn that MCP coordinate clicks /
# unscoped type are unsafe on canvas apps). When installed it exits immediately.
# The PreToolUse hook still warns on Claude-in-Chrome / Playwright calls even
# when agent-browser is missing.
#
# Bypass: HQ_NO_AGENT_BROWSER_NUDGE=1 silences the nudge.
# Exit codes: always 0.
set -uo pipefail

cat >/dev/null 2>&1 || true

[ "${HQ_NO_AGENT_BROWSER_NUDGE:-}" = "1" ] && exit 0
command -v agent-browser >/dev/null 2>&1 && exit 0

jq -nc '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:"agent-browser (HQ default for browser automation — policy hq-prefer-agent-browser) is not on PATH. Install once with: brew install agent-browser && agent-browser install (or npm install -g agent-browser && agent-browser install). Until then, browser/QA tasks fall back to MCP tools: on canvas apps (Google Docs) prefer DOM refs and keyboard — screenshot-coordinate clicks miss, and type can write into the document body. agent-browser cannot reuse a logged-in Chrome Google session; Google needs headed sign-in. Silence with HQ_NO_AGENT_BROWSER_NUDGE=1."}}' 2>/dev/null || true
exit 0
