---
id: chrome-mcp-multi-page-audit
title: Chrome MCP multi-page audit pattern
scope: global
trigger: chrome MCP multi-page testing, admin dashboard audits
enforcement: soft
public: true
---

## Rule

When auditing multiple pages via Chrome MCP:
1. `read_console_messages` tracking resets on every full page navigation (`navigate` tool or `window.location.reload()`). Cannot capture load-time console errors across page transitions.
2. `link.click()` via `javascript_tool` does NOT trigger Next.js App Router navigation for sidebar links. The router intercepts `<Link>` components differently from raw click events.
3. Reliable pattern: install a `console.error`/`console.warn` interceptor via `javascript_tool`, then use `navigate` tool for each page individually and check page text content for error banners (`Failed to load/fetch/connect`, `Something went wrong`, `Unhandled Runtime Error`).
4. `gh pr merge --squash` succeeds on GitHub even if local fast-forward fails — the local warning is cosmetic. Check PR state via `gh pr view --json state` to confirm.

## Rationale

Discovered during {your-project}-admin 17-page audit (Mar 2026). Multiple approaches tried before finding the reliable pattern.
