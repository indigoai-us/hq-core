---
id: hq-prefer-agent-browser
title: Prefer agent-browser CLI over Claude in Chrome for QA audits
scope: global
trigger: browser-based QA, page audits, site testing, smoke tests
when: browser || smoke
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
version: 2
created: 2026-03-24
updated: 2026-03-24
source: user-correction
public: true
---

## Rule

For browser-based QA audits, page-walking, and site testing, use the Vercel **agent-browser** CLI tool (invoked via `/agent-browser` skill) instead of Claude in Chrome MCP.

agent-browser advantages:
- Headed mode via `AGENT_BROWSER_HEADED=1` (user can see and interact)
- State persistence (`agent-browser state save/load`) for auth sessions
- Snapshot-based interaction (`agent-browser snapshot -i`) — no Chrome extension required
- Works without browser extension connection
- Supports parallel sessions, screenshots, and annotated captures

**CSR/Wix site scraping:** WebFetch returns only JS bootstrap code from client-side rendered sites (Wix, React SPAs). Use agent-browser with `--headed` and `wait --load networkidle` to get fully rendered content. The daemon model means commands chain with `&&` on the same browser instance. Use `--session {name}` for named sessions, `get text "body"` for text extraction, `screenshot --full` for full-page captures.

Reserve Claude in Chrome for tasks requiring real-time visual interaction or when agent-browser is unavailable.

## Rationale

User correction: Claude in Chrome requires an active extension connection that frequently disconnects. agent-browser is self-contained, supports headed mode for authentication, and has built-in state persistence for reusable auth sessions.
