---
id: session-data-for-product-accuracy
title: Analyze session threads before writing user-facing guides
scope: command
trigger: creating getting-started guides, cheatsheets, or curriculum for HQ/Empire OS
enforcement: soft
version: 1
created: 2026-03-29
updated: 2026-03-29
source: user-correction
---

## Rule

Before writing user-facing HQ guides or cheatsheets, analyze actual session data in `workspace/threads/` and `workspace/learnings/.observe-patterns*.json` to identify which commands are actually used. The curriculum outline and theoretical command list diverge significantly from real usage. Key discrepancies found: /search and /run {worker} {skill} appear in docs but are rarely used directly; the real loop is /startwork → /brainstorm → /plan → /run-project → /handoff.

