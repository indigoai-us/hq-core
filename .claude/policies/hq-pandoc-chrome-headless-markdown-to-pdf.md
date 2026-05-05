---
id: hq-pandoc-chrome-headless-markdown-to-pdf
title: Render markdown → PDF via pandoc → HTML → Chrome headless (no LaTeX)
scope: global
trigger: Rendering a markdown document to PDF (reports, summaries, long-form docs) and LaTeX/reportlab are overkill.
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

ALWAYS: For markdown → PDF without LaTeX, use pandoc → HTML → Chrome headless (`--headless --print-to-pdf`).

- Pandoc handles tables, TOC, metadata, and section numbering natively.
- Chrome respects `@page` CSS for page size and margins, `page-break-before` on `H1`, and `font-variant-numeric: tabular-nums` for monetary columns.
- Pipeline is lighter-weight than reportlab for long-form docs and avoids a ~4GB TeX Live install.

Typical invocation:

```bash
pandoc input.md -o tmp.html --standalone --css=print.css --metadata title="..."
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --no-pdf-header-footer \
  --print-to-pdf=output.pdf "file://$(pwd)/tmp.html"
```

## Rationale

Session rendering tax-packet PDFs (2026-04-21) confirmed pandoc+Chrome produces clean, paginated PDFs with tabular monetary columns and accurate page breaks — without pulling in LaTeX. reportlab is heavier to maintain for multi-section documents with tables; LaTeX install is a 4GB footprint that rarely pays off for one-shot financial summaries.
