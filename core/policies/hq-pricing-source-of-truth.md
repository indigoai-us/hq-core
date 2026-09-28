---
id: hq-pricing-source-of-truth
title: Quote HQ Pricing Only From pricing.json or the Live Endpoint
when: pricing || price || billing || invoice || cost
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
version: 1
created: 2026-09-26
updated: 2026-09-26
source: workforce-no-included-agents
public: true
---

## Rule

1. Quote HQ prices, plan allowances, included agents and billing rules only
   from `core/knowledge/public/hq-core/pricing.json` or the live endpoint,
   the HQ API pricing endpoint (`GET /v1/pricing` on the HQ API base, default https://hqapi.hq.computer).
2. Never quote HQ pricing from company knowledge docs, old PRDs, marketing
   drafts or memory.
3. If the shipped copy and the endpoint disagree, the endpoint wins. Say that
   the shipped copy is stale and name the field that differs.
4. When you answer, name the source you used. For how billing works, point to
   `core/knowledge/public/hq-core/pricing-and-billing.md`.
5. Hosted agents on the current Workforce price are billed per box. Do not say
   Workforce includes agents unless the source says so for that price.
