---
type: insight
domain: [engineering]
tags: [workflow-runner, resume, cache, replay, dependencies]
scope: global
source_session: T-20260820-131656-workflow-runner-added-resume
created: 2026-08-20
confidence: high
relates_to: []
---

# Strict-prefix cache replay protects dependent workflows

## Insight

Workflow results are only reusable while their full upstream history still
matches. When later agent prompts consume earlier results, a cached downstream
answer represents the exact earlier prefix that produced it, not merely an
independent function of its own prompt.

Stopping replay at the first cache-key mismatch preserves this dependency
meaning. Resuming from a later cache entry after an earlier live divergence
would silently combine results from two incompatible runs.

## Context

Use strict-prefix replay for sequential workflows whose later steps consume
earlier outputs. Check cache entries before concurrency limits so replayed work
does not occupy an execution slot that a live step needs.

