---
id: hq-debug-multi-hop-exhaust-all-layers
title: Multi-hop debugging — exhaust every layer before declaring fixed
scope: global
trigger: debugging a broken end-to-end flow with multiple hops (browser → CDN → app → upstream API → DB)
when: debug
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-28
updated: 2026-04-28
source: session-learning
---

## Rule

ALWAYS: When debugging a multi-hop end-to-end flow that's broken (e.g. browser → CDN → app → upstream API → DB), don't stop after fixing the first error you find. Each layer's failure mode often disguises the next layer's bug. Curl through every hop until you reach a 200 even after the first fix turns the symptom green.

## Rationale

Multi-hop flows have failure modes that cascade — fixing one layer often unmasks a different bug in the next. A symptom going "green" (e.g. a 4xx becoming a 5xx) can feel like progress but is not a fix. The only valid definition of done is a clean 200 response tracing the full path from entry to data store. Stopping at the first green signal leaves latent bugs in production that surface later under different conditions.
