---
id: hq-glob-scoped-path
title: Always Scope Glob with Path Parameter
scope: global
trigger: when using the Glob tool
when: glob || find
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 1
created: 2026-02-22
updated: 2026-02-22
source: migration
learned_from: "CLAUDE.md learned rules migration 2026-02-22"
public: true
---

## Rule

ALWAYS pass `path:` to Glob scoped to a subdirectory (e.g. `personal/projects/`, `companies/{co}/projects/`, `core/workers/`). Glob from HQ root times out (`.ignore` doesn't protect it). Grep from HQ root is safe (`.ignore` blocks repos/node_modules). Parallel tool failures cascade — one timeout kills all siblings.

## Rationale

HQ root has 1.38M+ files via symlinks. Unscoped Glob causes timeouts that kill all sibling parallel tool calls.
