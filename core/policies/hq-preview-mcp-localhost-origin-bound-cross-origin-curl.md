---
id: hq-preview-mcp-localhost-origin-bound-cross-origin-curl
title: Claude Preview MCP is origin-bound to its dev server — use curl for cross-origin prod verification
scope: global
trigger: verifying production deploys while Claude Preview MCP is attached to a local dev server
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

When the Claude Preview MCP server is bound to a local dev server (`localhost:PORT`, typically launched via `rtk init preview`), it cannot navigate to a different origin. Attempts to `preview_eval` with an absolute production URL (e.g. `window.location.assign('https://app.example.com/...')`) either fail silently, return the old dev-origin DOM, or produce a dead context. This is not a retryable condition — it is an architectural binding of the MCP session to the initial dev origin.

**For cross-origin production verification, always use `curl` against the production URL** (or `WebFetch` for HTML, `curl -I` for headers, `curl -s ... | grep` for response-body probing). The Preview MCP is strictly scoped to its bound localhost dev server.

If production-DOM verification is actually required (not just HTML/JSON), launch a separate Preview MCP session against the prod URL, or use `mcp__Claude_in_Chrome__*` which runs inside the user's actual browser and has no origin binding.

## Rationale

The preview MCP server spawns a headless browser and points it at the dev origin supplied at launch (e.g. `http://localhost:3001`). Same-origin policy plus the MCP's implicit session scope mean the page-controller refuses to load a document from a different registrable domain — the navigation call returns, but the DOM snapshot, click selectors, and eval context all continue to reference the original dev origin.

Attempting to verify a production deploy via `preview_eval` with a cross-origin URL returns the localhost DOM, leading to confused "the deploy didn't work" debugging when the production CSS was actually correct.

Curl (and WebFetch) are the right tool for HTTP-layer prod verification: they probe wire-level response bodies and headers without any session/origin baggage. Reserve Preview MCP for interacting with the bound dev server only.
