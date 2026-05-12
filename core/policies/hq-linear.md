---
id: hq-linear
title: Linear rules (consolidated)
scope: global
trigger: when working with Linear (issues, projects, MCP, sync)
enforcement: hard
version: 1
created: 2026-04-29
updated: 2026-04-29
applies_to: [linear]
public: true
tags: [vendor:linear, consolidated]
source: consolidation-merge
---

## Rule

Consolidated rules for working with Linear — covers authentication, GraphQL field semantics, batched mutations, and PRD sync hygiene. Sub-rules below preserve per-topic enforcement; the strictest applies (`hard`).

## Authentication

### Linear API keys use plain Authorization header, not Bearer
[from linear-api-no-bearer.md] — enforcement: hard

ALWAYS use `Authorization: <api_key>` (plain key, no prefix) when authenticating with the Linear GraphQL API. NEVER use `Authorization: Bearer <api_key>` — Linear rejects Bearer-prefixed API keys with a 400 error.

Linear API keys are not OAuth tokens. The API returns a clear error: "It looks like you're trying to use an API key as a Bearer token. Remove the Bearer prefix." This applies to all Linear workspaces.

## GraphQL field semantics

### Linear project/issue descriptions must be ≤255 chars — use `content` field for long bodies
[from hq-linear-project-description-255-char-cap.md] — enforcement: hard

Linear exposes TWO distinct text fields on projects and issues — they are NOT interchangeable:

- **`description`** — short summary, hard-capped at 255 chars. Rejected by `projectCreate`/`projectUpdate`/`issueCreate` with HTTP 400 / `ARGUMENT_VALIDATION_FAILED` when exceeded.
- **`content`** — long markdown body, effectively unlimited. This is where PRD full text, acceptance criteria, rationale, and any multi-paragraph narrative belong.

Any code path that syncs a PRD into Linear MUST split the payload accordingly:

1. **Short summary → `description` field** (≤230 chars, leaves ~25 char margin). If the source text exceeds 230 chars, truncate at the last word boundary ≤230 and append `…` (single-char ellipsis, not `...`).
2. **Full body → `content` field** (markdown). Do NOT truncate. Do NOT dump the long body into `description`.

Specifically, `/plan` Step 8 (Linear sync) must:

1. Extract a short summary from `prd.metadata.description` or the PRD README first-paragraph summary (≤230 chars after word-boundary truncation).
2. Extract the full PRD body (README or prd.json full description) for the `content` field.
3. Send both fields in the `projectCreate`/`issueCreate` input: `description` = short, `content` = long.

Do NOT rely on Linear returning a helpful error — the GraphQL 400 is opaque and costs a full retry cycle to surface. Enforce the cap client-side AND route long bodies to the correct field.

**Rationale:** Retry with truncation succeeded, but the root cause is not "the description was too long" — it's "the long body was written to the wrong field." Linear's `content` field is the proper home for multi-paragraph markdown. Collapsing both fields into a single truncated `description` loses information; routing long bodies to `content` preserves full PRD text and makes the 230-char `description` cap a trivial summary write. Same field split applies to `issueCreate` — don't dump acceptance criteria into the issue `description`. The 230-char target (not 255) reserves room for the ellipsis and any downstream append (e.g., `" [HQ-synced]"`) without re-truncating later.

## Batched mutations

### Batch Linear GraphQL mutations via aliases — never N+1 round-trips
[from hq-linear-batch-aliased-mutations.md] — enforcement: soft

When creating N Linear issues + their relations (parent/child, blocks, duplicates) programmatically, batch via aliased GraphQL mutations instead of firing N sequential HTTP requests. Linear's API fully supports multi-mutation documents with aliases:

```graphql
mutation BatchCreate {
  i1: issueCreate(input: {title: "Story 1", ...}) { issue { id } }
  i2: issueCreate(input: {title: "Story 2", ...}) { issue { id } }
  i3: issueCreate(input: {title: "Story 3", ...}) { issue { id } }
}
```

For PRD → Linear sync flows that create issues AND link them (parent/child relations), collapse the workflow to exactly TWO round-trips:

1. **Round 1:** Single aliased mutation that creates all issues. Capture the returned issue IDs keyed by alias.
2. **Round 2:** Single aliased mutation that creates all relations (`issueRelationCreate`) referencing the IDs from round 1.

Do NOT fire a separate HTTP request per issue. For a 15-story PRD, N+1 costs ~30 round-trips (~15s network time); batched costs 2 round-trips (~1s). More importantly, a partial failure mid-sequence leaves Linear in a half-synced state that's hard to recover from — batched mutations either fully succeed or fully fail with clear per-alias error paths.

**Rationale:** Linear's GraphQL API explicitly documents multi-mutation support and guarantees sequential execution within a document (aliases run top-to-bottom in a single transaction at the API layer). This is first-class, not a clever hack. Most Linear SDKs default to single-mutation helpers (`client.createIssue(...)`) which force N+1 — drop to the raw `client.rawRequest(query, variables)` or equivalent `fetch` for batch paths.

## PRD sync hygiene

### Linear scan must check existing PRDs before recommending new ones
[from linear-scan-check-existing-prds.md] — enforcement: hard

Before recommending a new PRD from a Linear scan, always check `companies/{product}/projects/` for existing PRDs that cover the same Linear issues. Use `ls companies/{product}/projects/` and read matching `prd.json` files to check `linearIssueId` fields against scan results.

