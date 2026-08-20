---
type: insight
domain: [engineering]
tags: [workflow-runner, json-schema, agent-output, recovery]
scope: global
source_session: T-20260820-131656-workflow-runner-added-resume
created: 2026-08-20
confidence: high
relates_to: [personal/policies/workflow-runner-off-contract-reformat.md]
---

# Bounded output repair preserves execution evidence

## Insight

An agent's prose reply after a structured-output request does not necessarily
mean that its task failed. Context compaction can preserve the work while losing
the output envelope, leaving the observable result out of contract rather than
making the work itself incomplete.

A repair pass is safe only when it is a constrained translation of evidence
already present: no tools, no additional task work, conservative interpretation
when the outcome is unclear, and validation against the original schema. Those
limits turn repair into recovery of evidence instead of an unbounded retry that
could create a second, divergent execution.

## Context

This applies to workflow systems that require machine-readable agent results.
It keeps a completed operation from being needlessly rerun while preserving the
same trust boundary as a first-pass structured response.

