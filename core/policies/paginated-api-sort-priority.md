---
id: paginated-api-sort-priority
title: Server-side sort by priority for paginated + filtered APIs
scope: cross-cutting
trigger: paginated API with client-side status filter
enforcement: soft
public: true
---

## Rule

When a paginated API serves data that the client filters by status/priority, add server-side `sort` param to return high-priority records first. Client-side filtering on page 1 of alphabetically-sorted data will show 0 results if all high-priority records are past the first page.

## Rationale

{company} field app loaded 50 accounts alphabetically — all churned. "Active" filter showed empty. Fix: `?sort=staleness` returns active accounts on page 1.
