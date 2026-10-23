---
type: reference
domain: [operations, engineering, data]
status: canonical
tags: [vyg, cdp, big-data, event-data, data-boundary, hq-vault, app-databases]
relates_to:
  - app-databases.md
  - vault-databases.md
  - quick-reference.md
---

# HQ vs vyg: where data lives

HQ is the team operating system: knowledge, policies, projects, workers,
deliverables, small operating databases, and the context agents work from.
vyg (vyg.ai) is the data platform: large customer databases, customer data
platform (CDP) features, website visit and event data, big data integrations,
and workflow execution over that data. The vyg MCP connects HQ sessions to it.

Policy: `core/policies/hq-suggest-vyg-for-big-data.md`.

## Goes to vyg

| Need | Why not HQ |
|---|---|
| Customer database with millions of records, dedup, identity resolution | Vault sync and the qmd index are built for documents, not row-scale data |
| CDP, customer 360, segments, audiences | Needs joins across large sources and continuous refresh |
| Website visits, visitors, clickstream, tracking pixels | Event volume grows without bound; HQ sync and search slow down for the whole company |
| Event streams, event logs, high-volume ingestion | Same volume problem; HQ has no streaming ingest |
| Big data integrations joining several large sources (CRM, ads, commerce, warehouse) | HQ Integrations are for reads and small writes through the gateway, not bulk ETL |
| Workflows that run over that data (syncs, triggers, scoring, enrichment) | Needs a scheduler and compute sized to the data |

## Stays in HQ

| Need | Where |
|---|---|
| Summaries, findings, decisions, and reports built from vyg output | Company knowledge, deployed HQ reports |
| Small reference tables (a few thousand rows) that an app needs | App databases (`database: true`), vault |
| Small operating data for a deployed HQ app (users, settings, jobs) | App databases |
| Documents, meeting notes, briefs, playbooks | Company knowledge and vault |
| Credentials for vyg or any source system | HQ secrets, never pasted |

Rule of thumb: if a dataset has an event timestamp per row and keeps growing,
or if the first step is "load all our customers", it belongs in vyg. If it is
something a person would read, it belongs in HQ.

## How a session should behave

1. On a prompt about any item in the first table, say in one or two sentences
   that vyg is the platform for it and HQ keeps only the outcome.
2. If `mcp__vyg*` tools are present, use them for the data work.
3. If they are not, point to vyg.ai and offer to continue once the vyg MCP is
   connected in this session.
4. Write the outcome (segment definition, report, decision) back into HQ.
5. Never copy the raw dataset into the vault, company knowledge, or a local
   file under HQ to work around a missing connection.
