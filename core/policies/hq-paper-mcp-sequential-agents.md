---
id: hq-paper-mcp-sequential-agents
title: Paper MCP agents must work sequentially on shared canvas
scope: global
trigger: spawning sub-agents for Paper design work
enforcement: soft
version: 1
created: 2026-03-24
updated: 2026-03-24
source: success-pattern
public: true
---

## Rule

When spawning sub-agents for Paper MCP design work, agents MUST run sequentially — never in parallel. Paper operates on a single shared canvas; two agents writing HTML nodes simultaneously create overlapping artboards and corrupted layouts.

Parallelism comes in the code build phase (independent file trees), not the design phase (shared canvas).

Effective pattern: Design System agent first (establishes tokens) → Desktop pages agent → Mobile pages agent → QA agent. Each completes and calls `finish_working_on_nodes` before the next starts.

## Rationale

Paper MCP's `write_html` and `create_artboard` tools operate on the same document state. Concurrent writes from parallel agents would produce non-deterministic artboard placement and potential node ID conflicts.
