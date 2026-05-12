---
id: hq-toolsearch-load-deferred-schemas
title: Load deferred tool schemas via ToolSearch after resumed/compacted sessions
scope: global
trigger: InputValidationError on TodoWrite/WebFetch/etc, resumed session, post-compaction, deferred tool list present
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

After a resumed or auto-compacted session, many commonly-used tools (`TodoWrite`, `WebFetch`, `WebSearch`, `AskUserQuestion`, `ExitPlanMode`, MCP tools, etc.) may appear in the **deferred tools** list rather than being directly invocable. Calling a deferred tool by name returns `InputValidationError: tool X not found` because only the name is known — the parameter schema has not been loaded.

Before invoking any tool that is listed as deferred:

```
ToolSearch query:"select:TodoWrite"
ToolSearch query:"select:WebFetch,WebSearch"
```

The `select:` prefix takes exact tool names (comma-separated). After ToolSearch returns the schema in a `<functions>` block, the tool becomes callable normally for the remainder of the session.

Signals that tools are deferred:
- SessionStart system-reminder lists "The following deferred tools are now available via ToolSearch"
- First invocation of a previously-working tool returns `InputValidationError`
- Session was resumed from a previous transcript or just survived autocompact

## Rationale

Claude Code defers tool schemas on session resume and post-compaction to save context window. The deferred list is addressable but not invocable until its schema is explicitly fetched. Calling the tool directly in this state fails validation — and the error message doesn't always make the remediation obvious. Defaulting to `ToolSearch select:<name>` before the first call of any commonly-deferred tool avoids a wasted turn.
