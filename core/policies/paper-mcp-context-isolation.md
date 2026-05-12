---
id: hq-paper-mcp-context-isolation
title: Paper MCP context isolation — delegate heavy reads to sub-agents
scope: global
trigger: mcp__paper__get_jsx, mcp__paper__get_tree_summary (canvas root), mcp__paper__get_node_info (containers), mcp__paper__get_computed_styles (>1 node), mcp__paper__get_children (>depth 2), multi-artboard extraction, "re-fetch the JSX payloads", design token extraction across artboards
enforcement: hard
tier: 1
version: 1
created: 2026-05-11
updated: 2026-05-11
source: back-pressure-failure
learned_from: a multi-artboard design extraction session crashed by autocompact thrashing
public: true
---

## Rule

The parent session must never accumulate raw Paper MCP node-tree payloads across multiple artboards. For any Paper read that returns full node structure, delegate to a sub-agent that returns text-only findings (a compact summary plus the specific values needed: hex colors, px sizes, font names, copy).

### Delegation pattern

1. Parent spawns a sub-agent via Agent tool with a self-contained brief: which artboards to read, which Paper tools to call, and what shape to return ("palette, type scale, spacing, copy as a markdown table — text only, no raw JSX").
2. Sub-agent loops over artboards in its isolated context, calling `get_jsx` + `get_computed_styles` per artboard.
3. Sub-agent returns a distilled summary (~1 KB).
4. Parent receives text — zero raw JSX bytes in its window.

### MUST delegate (hard rule)

- Any extraction touching more than one artboard
- `get_jsx` on more than one node tree
- `get_tree_summary` rooted at the canvas (not a small container)
- `get_computed_styles` requested across more than one node
- `get_children` past depth 2
- `get_node_info` on a container with unknown depth
- Trigger phrases that imply batch reads: "re-fetch the JSX payloads", "extract design tokens from the artboards", "read all N artboards", "pull all the layers"

### MAY skip delegation (exceptions)

- A single small node selection inspected with `get_jsx` once
- `get_basic_info`, `get_selection`, `get_font_family_info`, `get_guide` (small bounded payloads)
- Write-side tools: `write_html`, `update_styles`, `set_text_content`, `rename_nodes`

### Tool-specific rules

| Tool | Parent-safe? | Notes |
|------|--------------|-------|
| `get_basic_info`, `get_selection`, `get_font_family_info`, `get_guide` | Yes | Small bounded payloads |
| `write_html`, `update_styles`, `set_text_content`, `rename_nodes`, `duplicate_nodes`, `delete_nodes` | Yes | Write-side, no large reads |
| `get_jsx` (single small selection) | Maybe | One node tree, one call only |
| `get_jsx` (>1 artboard or large node tree) | NO — sub-agent | 5–15 KB per artboard |
| `get_tree_summary` on canvas root | NO — sub-agent | Scales with file complexity |
| `get_node_info` on a container (deep tree) | NO — sub-agent | Unknown payload size |
| `get_computed_styles` (>1 node) | NO — sub-agent | 1–3 KB per node |
| `get_children` past depth 2 | NO — sub-agent | Recursive expansion |

### Worked example

**Bad pattern (causes autocompact thrashing):**

```text
Parent calls:
  mcp__paper__get_jsx(artboard_1)     → 12 KB into parent context
  mcp__paper__get_jsx(artboard_2)     → 12 KB
  mcp__paper__get_jsx(artboard_3)     → 12 KB
  ... 6 × 12 KB = ~72 KB of raw JSX in parent
Autocompact fires, frees ~40% of context.
Parent retries the same chain — refills freed space.
After 3 consecutive compactions within ~3 turns, the API thrashing guard kills the session.
```

**Good pattern (text-only distillation):**

```text
Parent spawns 1 Explore sub-agent with a brief:
  "Loop over artboards [1..6] in this Paper file. For each, call get_jsx +
   get_computed_styles. Return a single markdown table covering palette,
   type scale, spacing scale, and any verbatim copy. Text only, no JSX."

Sub-agent context absorbs all 6 × (12 KB + node styles) = ~90 KB.
Sub-agent returns a ~1 KB table.
Parent context grew by ~1 KB, not ~90 KB. No compaction triggered.
```

## Rationale

`get_jsx` returns the full JSX representation of a Paper node tree — roughly 5–15 KB per artboard depending on layer count. When a parent session reads multiple artboards sequentially, the cumulative payload can fill the freed context after every autocompact, immediately re-triggering compaction. The Claude API enforces a thrashing guard that kills the session after three consecutive compactions within ~3 turns.

The model cannot recover from this once the payloads are in its window — only architectural prevention works. Sub-agents have isolated context windows; they can swallow the full JSX, distill it, and return text. The parent never sees the raw bytes.

This policy mirrors the proven `image-context-isolation.md` pattern (parent never accumulates >10 images), applied to MCP tools whose responses scale with design complexity.
