---
id: no-headless-browser-in-vercel-lambda
enforcement: hard
scope: global
tags: [vercel, lambda, playwright, puppeteer, chromium]
public: true
created: 2026-04-15
provenance: back-pressure-failure
---

## Rule

NEVER run Playwright, Puppeteer, or Chromium in a Vercel Lambda. Use ingest-only endpoints that accept pre-captured payloads from client-side callers (extensions, local scripts).

## Rationale

The 250 MB unzipped Lambda cap makes shipping a headless browser architecturally impossible. Attempts to slim the binary or chunk dependencies do not close the gap; the architecture has to move the browser-execution side off Lambda entirely. Confirmed via back-pressure failure 2026-04-15.
