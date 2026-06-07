---
id: hq-migration-bidirectional-grep-verify
title: Verify content/brand migrations with both positive and negative production scans
scope: global
trigger: brand migration verification, content migration verification, copy replacement rollouts
when: migrate || migration || schema
on: [PreToolUse, UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: session-learning
---

## Rule

When verifying a brand or content migration in production, run BOTH directions of evidence and require BOTH to pass:

1. **Positive scan**: count occurrences of the new copy in served HTML — must be ≥ expected count
2. **Negative scan**: count occurrences of the old copy in served HTML — must be exactly zero

A passing positive scan alone is insufficient regression evidence. Partial replacements (some pages updated, some leftover, mixed-template pages) all return high positive counts while still leaking the old brand to customers — exactly the failure mode the migration was supposed to eliminate.

## Rationale

Brand-leak bugs reach customers via partial replacements that look fine on a positive-only audit. The negative scan is the only direct test of the absence claim ("no surface still says X"). Together the two scans assert both completeness (new copy is everywhere it should be) and exclusivity (old copy is nowhere). Cheap to run, catches the most embarrassing class of migration bug.
