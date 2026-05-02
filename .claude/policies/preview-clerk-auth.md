---
id: preview-clerk-auth
title: Preview tools cannot render Clerk-authed apps
scope: global
trigger: preview verification of Clerk-protected apps
enforcement: soft
public: true
---

## Rule

Preview tools (preview_screenshot, preview_snapshot) render blank for apps using Clerk middleware auth. The headless browser has no Clerk session. Verify via build check + earlier screenshots if available, or use agent-browser with cookie import.

## Rationale

Build verification (TypeScript + Next.js static generation) catches structural issues. Visual verification requires a real browser session.
