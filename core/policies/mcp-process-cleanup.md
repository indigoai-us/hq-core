---
id: mcp-process-cleanup
title: MCP Server Process Cleanup
scope: global
trigger: session-end, mcp-server
when: mcp || .mcp.json
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
created: 2026-04-06
public: true
---

## Rule

MCP servers spawned via stdio (npx/tsx) leak as orphaned processes when Claude sessions end. The `cleanup-mcp-processes` Stop hook kills these on session exit. This hook MUST remain in all profiles (minimal, standard, strict).

Known leakers:
- `slack-mcp/src/server.ts` — 2 node processes per session (~200MB each)
- `advanced-gmail-mcp/src/server.ts` — disabled 2026-04-06, was leaking same pattern
- `agent-browser` — Chromium engine, 2-4 GB per leaked instance
- `detached-flush.js` — Next.js telemetry orphans (~100MB each)

## Rationale

Diagnosed 2026-04-06: 250+ GB RAM usage crashed machine (96 GB physical). Root cause was 12+ orphaned Slack MCP server instances accumulated across sessions. Node.js/tsx processes ignore SIGHUP, so they survive parent Claude process termination.
