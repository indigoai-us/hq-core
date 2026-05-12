---
id: hq-distributed-join-partial-failure-diagnosis
title: Partial join failure points to visitor-id divergence on specific pages, not pipeline-wide bugs
scope: global
trigger: debugging an analytics/experiment/event join where some event types match and others don't (not total silence)
enforcement: soft
public: true
version: 1
created: 2026-04-17
updated: 2026-04-17
source: session-learning
---

## Rule

When a distributed join shows "some events match, others don't" (e.g. Install/Activated join successfully while Lead joins zero), suspect **visitor-id divergence on specific pages** rather than a pipeline-wide failure. Same tracker + different pages + different cookie accessibility = different visitor IDs ending up in the event stream, and only some happen to live in the assignments map.

Fix pattern (defense in depth — do all three):
1. Seed join-key cookies earlier in the request lifecycle so every entry path gets them (close middleware matcher gaps)
2. Explicitly stamp join keys (`visitor_id`, `variant_id`, `experiment_id`) inside event data payloads — don't trust envelope-level fields alone
3. Server-side join should read data-level keys as fallback when envelope-level keys don't match the assignment map

## Rationale

Observed on a {company} A/B framework: 8,456 assigned visitors, Install/Activated events joined fine, Lead events joined zero. Root cause was three compounding failures — middleware matcher excluded `/account/*`, HQProvider fell back to a localStorage-minted UUID when cookies were absent, and `getABVariant()` returned null — but the diagnostic shortcut is the asymmetry itself. Total pipeline silence would suggest schema/transport bugs; partial silence by event type points directly at page-specific cookie accessibility.
