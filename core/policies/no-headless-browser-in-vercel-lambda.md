---
id: no-headless-browser-in-vercel-lambda
when: lambda || vercel || browser
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
tags: [vercel, lambda, playwright, puppeteer, chromium]
created: 2026-04-15
provenance: back-pressure-failure
---

## Rule

NEVER run Playwright, Puppeteer, or Chromium in a Vercel Lambda. Use ingest-only endpoints that accept pre-captured payloads from client-side callers (extensions, local scripts).
