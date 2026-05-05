---
id: paper-text-wrapping
title: Paper MCP text nodes require manual line breaks
scope: global
trigger: paper mcp, design, text wrapping
enforcement: soft
version: 1
created: 2026-03-26
updated: 2026-03-26
public: true
---

## Rule

Paper MCP text nodes do NOT respect `width` or `max-width` for text wrapping. Text renders as a single unwrapped line regardless of container or node width settings. When text must wrap to a specific width, break it manually into separate `<span>` elements — one per visual line. This applies to body copy, descriptions, and any multi-line text content.

## Rationale

Multiple attempts to constrain text width (on the node, on a wrapper div, with flexShrink) all failed. Manual line breaks were the only reliable solution in Paper.
