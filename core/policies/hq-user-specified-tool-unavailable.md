---
id: hq-user-specified-tool-unavailable
title: Pause and ask when a user-specified tool is unavailable
scope: global
trigger: tool unavailable, mcp not loaded, paper mcp, specific tool requested, tool not found
enforcement: hard
tier: 1
version: 1
created: 2026-04-16
updated: 2026-04-16
source: user-correction
public: true
---

## Rule

When the user explicitly instructs you to use a specific tool (e.g. "use Paper MCP", "use the Slack MCP", "use Playwright") and that tool is **not available** (not loaded, not in the deferred tools list, connection failure):

1. **Stop immediately** — do not attempt to perform the task by another means
2. **Tell the user** the tool is unavailable
3. **Ask explicitly**: "Would you like to (a) repair the connection / try loading the tool, or (b) use an alternative method?"
4. **Wait** for their answer before proceeding

Do NOT silently substitute an alternative tool or method. The user's specification of a tool is intentional — they may have strong reasons (visual output format, integration, workflow) that make the alternative unsuitable.

## Rationale

The correct behavior (successfully applied that session) is to pause and ask the user how to proceed — not to silently switch to an HTML preview, a code export, or any other fallback. Applies to all tools, not just Paper MCP.
