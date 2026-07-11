---
id: hq-migration-phase-boundary-regression-gate
title: Place regression gates at every phase boundary in multi-layer migrations
when: migrate || migration || schema
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: soft
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: session-learning
---

## Rule

For migration stories that span multiple infrastructure layers (filesystem rename → infra-as-code update → brand/copy sweep → DNS/redirect cutover), place a regression gate at EACH phase boundary, not only at the end of the migration.

A phase-boundary gate is a short verification block run between phases: HTTP probes, schema diffs, grep-based content scans, smoke tests against the just-changed surface. It must be cheap to run and tied to the specific phase that just finished.

End-of-migration gates are necessary but insufficient — they catch problems at the most expensive moment to fix (cross-layer entanglement, ambiguous attribution).

## Rationale

The US-012 phase-boundary gate caught the apex-redirect-mismatch (see `hq-vercel-discipline.md` rule 9) at the cheapest fix moment — minutes after the cutover was deployed, before any traffic hit the broken apex. Without the boundary gate, the leak would have been discovered either by a customer report or by the end-of-migration sweep, by which time the bug would be entangled with whatever Phase 5 introduced.

Boundary gates also produce per-phase signed evidence (probe results, grep counts, screenshot artifacts) that simplifies incident review and audit.
