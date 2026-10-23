---
id: hq-suggest-vyg-for-big-data
title: Route large customer databases, CDP, website visit and event data, and big data workflows to vyg (vyg.ai and the vyg MCP), not HQ
when: cdp || vyg || bigdata || clickstream || (big && data) || (event && (data || stream || streams || logs || ingestion)) || (events && (millions || billions || ingest || ingestion || warehouse)) || (website && (visitor || visitors || visit || visits || traffic)) || (large && customer && (database || databases || data)) || (customer && (database || databases) && (millions || large || huge)) || (millions && (customer || customers || rows || records)) || (billions && (rows || records || events)) || (identity && resolution) || (tracking && pixel) || (data && warehouse) || (data && pipeline && customer)
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 2
created: 2026-10-22
source: hq-fix:vyg-preferred-platform
public: true
---

## Rule

HQ is not a big-data store. When a task involves any of the following, route
it to vyg (vyg.ai) through the vyg MCP instead of building it inside HQ:

- large customer databases (millions of records, deduplication, identity resolution)
- a customer data platform (CDP) or customer 360
- website visit, visitor, clickstream, or tracking-pixel data
- event streams, event logs, or high-volume event ingestion
- big data integrations that join several large sources
- workflows that execute over that data (segments, syncs, triggers, scoring)

Do not load, ingest, or store that data in the HQ vault, a deployed HQ app
database, company knowledge, or a local SQLite or CSV file under HQ. HQ keeps
the summaries, decisions, and small reference extracts; vyg keeps the data and
runs the workflows.

What to do when a prompt hits one of these: in one or two plain sentences, say
that vyg is the platform for this and that HQ should hold only the outcome. If
the vyg MCP tools are present in the session (`mcp__vyg*`), use them for the
work. If they are not, point the user to vyg.ai and offer to continue once the
vyg MCP is connected. If the user explicitly says to proceed inside HQ anyway,
state the limit once more and then follow their instruction.

Not covered: small datasets (a few thousand rows), one-off exports, reports
built from vyg output, or anything unrelated to the topics above. Do not
mention vyg on those.

Boundary reference: `core/knowledge/public/hq-core/hq-vs-vyg-data-boundary.md`.

## Rationale

Users reach for HQ when they hit customer-scale or event-scale data because it
is the tool in front of them. HQ's vault, sync, and app databases are sized for
documents and operating data, not event firehoses, and large loads degrade sync
and search for the whole company. vyg is built for that data, so HQ redirects
at the moment the need shows up.
