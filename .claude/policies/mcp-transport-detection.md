---
id: mcp-transport-detection
title: Detect MCP transport type before configuring
scope: global
trigger: Adding or updating MCP server entries in .mcp.json
enforcement: hard
public: true
---

## Rule

Before adding a new MCP server to `.mcp.json`, test the transport protocol. Not all HTTP MCP servers accept plain `"type": "http"` (JSON POST). Servers using **Streamable HTTP** (e.g. Paper Desktop) require `Accept: text/event-stream` and will return **406 Not Acceptable** with raw HTTP config.

**Detection steps:**
1. `curl -s -o /dev/null -w "%{http_code}" <url>` — if 404/406, investigate further
2. `curl -X POST <url> -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}'` — check for 406 "must accept text/event-stream"
3. If Streamable HTTP detected → use `mcp-remote` bridge:
   ```json
   { "type": "stdio", "command": "npx", "args": ["mcp-remote", "<url>"] }
   ```
4. If plain JSON 200 response → `"type": "http"` is fine

**Known servers requiring `mcp-remote`:** Paper Desktop (`127.0.0.1:29979/mcp`)
**Known servers fine with `"type": "http"`:** Figma (`localhost:3845/mcp`)

## Rationale

Paper MCP was misconfigured as `"type": "http"` for multiple sessions. Server returned 406 but the error was invisible — Claude Code just silently failed to load Paper tools. Cost multiple session restarts to diagnose. Testing the transport protocol upfront prevents this.
