---
id: clipboard-file-protocol
title: navigator.clipboard fails on file:// — use textarea fallback first
scope: global
trigger: HTML reports, content review pages
enforcement: soft
created: 2026-03-31
public: true
tier: 1
---

## Rule

`navigator.clipboard.writeText()` requires a secure context (HTTPS). Pages opened via `file://` protocol will always reject the Clipboard API. When building HTML reports that run locally:
- Use the textarea + `document.execCommand('copy')` fallback as the PRIMARY method
- Fall back to `navigator.clipboard` only if execCommand fails
- Position the textarea offscreen (`position: fixed; left: -9999px`) to avoid visual flash

## Rationale

The `file://` protocol is not a secure context.
