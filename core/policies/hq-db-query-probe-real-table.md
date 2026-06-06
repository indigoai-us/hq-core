---
id: hq-db-query-probe-real-table
title: Probe the real table when shipping a new DB query pattern
scope: global
trigger: adding or changing a DynamoDB / SQL / Mongo query shape in a production code path
when: query || sql
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

ALWAYS: When shipping a new DB query pattern (new Scan/Query shape, new index usage, new WHERE clause), probe the real table during development before merging. Run the query against a dev/staging DB with representative data and confirm it returns what you expect.

NEVER: Treat a green unit suite that mocks at the module boundary (`vi.mock` of the resolver, jest.mock of the DB client, etc.) as evidence the underlying DB call works. Those mocks bypass the exact layer where query-shape bugs hide — FilterExpression semantics, index selection, GSI projection, pagination behavior, composite key encoding, etc.

Minimum acceptable probe:
1. Run the query against the real (dev) table
2. Verify the returned shape AND count match expectation for at least one positive and one negative case
3. Record the probe in the PR description or commit body

## Rationale

Surfaced while debugging a DDB Scan bug (see `hq-ddb-scan-no-limit-with-filter`). The auth resolver had a full unit suite passing green — every test mocked the resolver itself at the import boundary, so the underlying `Scan({Limit, FilterExpression})` call was never exercised. The query-shape bug shipped to production and only surfaced as a login failure in a fresh environment.

Integration tests against a real table (or Localstack / DynamoDB Local) would have caught it. When that infra is unavailable, a manual probe during dev is the minimum bar — a one-minute `aws dynamodb scan` or test script is cheaper than a rollback.
