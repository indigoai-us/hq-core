---
id: hq-smoketest-tracking-via-destination-stats-api
title: Verify cross-origin tracking smoketests by querying the destination service's own public stats endpoint via bash curl
scope: global
trigger: smoketesting that a tracking event fired from a browser tab actually landed in a downstream analytics / events service
enforcement: soft
public: true
version: 1
created: 2026-04-19
updated: 2026-04-19
source: session-learning
---

## Rule

When you need to verify that a tracking event fired from a webpage actually landed in a downstream analytics / events service (GTM HQ, an internal events API, a custom ingest), do NOT try to verify by `fetch`-ing the destination from the same browser tab — cross-origin requests will be blocked by CORS unless the destination has explicitly allowlisted the source origin (which production analytics endpoints generally do not).

Instead, after the in-page action fires:

1. Identify the destination service's own public stats / rollup endpoint (e.g. GTM HQ exposes `/api/events/stats?byType=...`).
2. Query that endpoint from a separate `bash curl` call (server-to-server, no browser, no CORS).
3. Diff the count or look for the new event by `visitor_id` / timestamp window.

This lets you smoketest end-to-end (browser → destination) without needing a CORS allowance, without requiring a debug overlay in the tab, and without polluting the source page's runtime.

## Rationale

During a tracking smoketest, the reflex was to run `fetch(GTM_HQ_URL + '/api/events/stats')` from inside the tab via the Claude-in-Chrome MCP javascript_tool. The working pattern was to run `curl -s https://gtm-hq.example/api/events/stats?byType=cta_click` from bash, which reads the destination's own rollup with no CORS involvement. Same data, different transport. This is a generic pattern for any cross-origin verification flow.
