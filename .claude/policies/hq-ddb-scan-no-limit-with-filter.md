---
id: hq-ddb-scan-no-limit-with-filter
title: Never combine DDB Scan Limit with FilterExpression
scope: global
trigger: writing a DynamoDB Scan or Query with a FilterExpression
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
applies_to: [aws]
---

## Rule

NEVER: Use DynamoDB `Scan` with both `Limit` and `FilterExpression` on a hot path. `Limit` caps the pre-filter row count, not post-filter matches — if the matching row isn't in the first N scanned items, the Scan returns empty even though the row exists.

ALWAYS: For bounded latency with a filter, paginate with `LastEvaluatedKey` (cap iterations + total time) OR use a GSI / `Query` for O(1) lookup. On auth / login / session-resolution paths, always prefer a GSI — retries during login are user-visible.

Safe shapes:
- `Query` on a PK (or GSI PK) — `Limit` applies to matching items
- `Scan` without `FilterExpression` — `Limit` applies to returned items
- `Scan` with `FilterExpression` + pagination loop bounded by a hard `maxIterations` AND a total-time budget

## Rationale

Surfaced while debugging a Cognito session-resolution bug: a `Scan` with `Limit: 20` + `FilterExpression` returned empty despite the row being present — the target item sat past position 20 in the table's hash-ordered scan. Tests that mocked the resolver at the module boundary never saw the query shape; the bug only appeared in the real table.

DDB docs describe this clearly but the footgun is that the empty result is indistinguishable from "no match" at the caller. Auth paths treating "empty" as "not authorized" silently lock users out.
