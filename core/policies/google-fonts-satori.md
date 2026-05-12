---
id: google-fonts-satori
title: Google Fonts TTF URLs for Satori/next-og
scope: global
trigger: OG image generation, next/og, ImageResponse
enforcement: soft
public: true
---

## Rule

When loading fonts for `next/og` (Satori), never hardcode Google Fonts gstatic URLs — they change with font versions (e.g., v22 → v24). Instead, fetch the CSS from the Google Fonts API first to get the current TTF URL:

```bash
curl -s "https://fonts.googleapis.com/css2?family=Font+Name:wght@400&display=swap" -H "User-Agent: Mozilla/5.0"
```

Extract the `url(...)` from the response. The User-Agent header is required — without it, Google returns WOFF2 instead of TTF.

## Rationale

Discovered 2026-03-11: Hardcoded gstatic font URLs returned 404 (wrong version path), causing `Unsupported OpenType signature <!DO` build error. Fetching CSS first gives the current versioned URL.
