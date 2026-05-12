---
id: hq-pandoc-chrome-single-page-financial-css
title: Single-page financial summary CSS baseline (pandoc → Chrome)
scope: global
trigger: User asks for a "single-page" financial summary (or similar dense one-pager) rendered via the pandoc → Chrome headless pipeline.
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

ALWAYS: When a user asks for a "single-page" financial summary rendered via the pandoc → Chrome pipeline, start with these CSS baselines:

- Body font size: **8.5pt**
- Page margins (`@page`): **0.45in**
- Table cell padding: **2.5px**
- Line-height: **1.32**
- Monetary columns: `font-variant-numeric: tabular-nums`

These settings fit approximately 3 tables + a 6-item numbered list + a header on a single US-letter page with acceptable readability. Adjust up one step (9pt / 0.5in / 3px / 1.35) if content is shorter; otherwise keep this as the default starting point and iterate from there.

## Rationale

Validated 2026-04-21 while building one-page tax-packet summaries. Smaller (8pt / 0.4in) cramped the tables; larger (9pt / 0.5in / 3px) pushed content to page 2. The 8.5/0.45/2.5/1.32 quad is the known-good baseline that consistently produces single-page output for this shape of document.
