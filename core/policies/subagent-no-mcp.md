---
id: hq-subagent-no-mcp
title: Sub-Agents Lack MCP Server Access
scope: global
trigger: when spawning Task() sub-agents that need external tools
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

Sub-agents spawned via Task() don't inherit MCP server connections. Workers needing external tools (Codex, etc.) must use CLI via Bash, not MCP tools declared in worker.yaml.

## Rationale

Task() sub-agents run in isolated contexts without MCP server inheritance.
