---
id: hq-data-collection-isolation
title: Isolate high-volume data collection from parent session
scope: global
trigger: Any recurring monitoring, dashboard, health check, or bulk data pull
when: monitor || dashboard
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
version: 1
created: 2026-04-03
updated: 2026-04-03
source: success-pattern
public: true
---

## Rule

NEVER pull high-volume monitoring data (metrics, health checks, dashboards) inline in the parent session — each tick burns 50K+ tokens of tool results.

Instead:
1. **Recurring runs** → use `mcp__scheduled-tasks__create_scheduled_task` (persistent, isolated session per run)
2. **Ad-hoc "run it now"** → spawn `Agent(run_in_background=true)` to collect data and format the dashboard. Parent receives only the compact summary.

The parent session should only see the final formatted output, never raw query results.

## Rationale

During an early health-monitor build (2026-04-03), running the cron inline consumed ~50K tokens per 10-minute tick. Six ticks burned half the context window. Moving to scheduled tasks (isolated sessions) and background agents for ad-hoc runs eliminated context bleed entirely.
