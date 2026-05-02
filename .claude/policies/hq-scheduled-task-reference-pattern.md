---
id: hq-scheduled-task-reference-pattern
title: Scheduled task SKILL.md is overwritten by prompt — use REFERENCE.md for details
scope: global
trigger: creating or updating scheduled tasks via mcp__scheduled-tasks__create_scheduled_task or update
enforcement: soft
version: 1
created: 2026-04-01
updated: 2026-04-01
source: success-pattern
public: true
---

## Rule

When creating or updating a scheduled task via the scheduled-tasks MCP tools, the system overwrites `SKILL.md` with the `prompt` parameter content. Any detailed reference material (SQL queries, message formats, remediation tables, thresholds) stored directly in SKILL.md will be lost on the next update.

ALWAYS store detailed reference material in a separate `REFERENCE.md` file alongside `SKILL.md` in the same `~/.claude/scheduled-tasks/{taskId}/` directory. The prompt in SKILL.md should instruct the agent to "Read the REFERENCE.md for exact queries and full instructions."

## Rationale

The full SKILL.md with SQL queries was overwritten twice — once on create and once on update — before the pattern was identified. REFERENCE.md is not managed by the scheduled-tasks system and persists across updates.
