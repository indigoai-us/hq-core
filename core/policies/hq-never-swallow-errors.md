---
id: hq-never-swallow-errors
title: Never Swallow Errors — All Failures Must Be Visible
scope: global
trigger: writing error handling, catch blocks, API response handling, webhook handlers, background jobs
when: always
on: [SessionStart]
enforcement: soft
tier: 1
version: 1
created: 2026-04-02
updated: 2026-04-02
source: session-learning
public: true
---

## Rule

1. **NEVER write a catch block that returns null, undefined, empty array, or a success status without logging the error.** Every catch block must either re-throw, log at ERROR level with context, or return an explicit error object that callers can inspect.
2. **NEVER return HTTP 2xx from an endpoint that encountered an error.** If processing failed, return 4xx/5xx. A 204 No Content that hides a failure is a bug, not defensive coding.
3. **ALWAYS check `.error` on Supabase/PostgREST responses before using `.data`.** The client returns `{ data: null, error: {...} }` on failure — not an exception. Treat unchecked `.error` as equivalent to an uncaught exception.
4. **ALWAYS validate webhook payloads explicitly and log rejections.** If a Pydantic model, Zod schema, or manual check rejects a payload, log the rejection reason and the payload identifier (order ID, event type, etc.) at WARN or ERROR level. Silent validation rejection is invisible data loss.
5. **Background jobs and queue handlers MUST log failures with enough context to identify the affected records.** Include entity IDs, event types, and timestamps. A failed `putEvent()` with no log means orphaned records that nobody knows about.

## Rationale

Silent error propagation caused the worst incidents in HQ history: Pydantic validation silently rejected checkout webhooks causing 98% checkout drop across 22+ brands for 2 days with zero alerts. PostgREST `.error` fields went unchecked, propagating null through the frontend. `putEvent()` failed silently creating 9,013 zombie checkouts. A handler returning 204 No Content hid complete data loss from operations.
