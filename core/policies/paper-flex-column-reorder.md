---
id: paper-flex-column-reorder
title: "Paper MCP: flex-column artboards require delete-rebuild for reordering"
scope: tool
trigger: "Paper MCP write_html into flex-column artboards"
enforcement: soft
public: true
---

## Rule

When a Paper artboard uses `display: flex; flex-direction: column` (most page-level artboards do), `write_html insert-children` always appends new nodes at the END of the children list. There is no reorder/move tool.

To interleave new sections between existing ones: delete the sections that need to shift down, then rebuild them (along with new sections) in the correct visual order via sequential `write_html` calls. Use `get_tree_summary` and `get_computed_styles` beforehand to capture content and styles for accurate rebuilds.

**Why:** Paper has no layer reorder API. Flex column layout renders children in layer order — visual position = insertion order. Attempting to just append new sections results in all new content appearing below the footer.

**How to apply:** Before any multi-section Paper expansion, plan the full target section order. Identify which existing sections need repositioning. Capture their structure/styles, delete them, then rebuild everything in sequence.

## Rationale

Five new sections needed to be interleaved between existing Product Grid, Subscribe Banner, Comparison Table, and Footer. Without delete-rebuild, all new sections would stack below the footer.
