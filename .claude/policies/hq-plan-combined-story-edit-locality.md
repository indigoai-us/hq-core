---
id: hq-plan-combined-story-edit-locality
title: "'One combined, minimum story plan' overrides brainstorm P1/P2 split — group by edit locality"
scope: global
trigger: /plan after /brainstorm, user requests combined/minimum story plan
enforcement: soft
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: user-correction
---

## Rule

When the user says "create one combined, minimum story plan" (or any phrasing that asks for a single consolidated story set) after a `/brainstorm` has produced a recommended P1/P2/phased split:

1. **Override the brainstorm's phase split.** Do NOT carry P1/P2 tiers, risk bands, or sequencing recommendations into the PRD.
2. **Group stories by edit locality — the set of files touched — not by phase, risk, or theme.** Stories that edit the same file or tightly coupled files belong in the same story. Stories that touch disjoint file sets stay separate.
3. **Aim for the minimum story count that preserves meaningful commit boundaries.** If three brainstorm items all edit `src/lib/accounts-data.ts`, they collapse into one story. If a fourth item edits `src/lib/revenue-data.ts`, it stays separate.
4. **Do not re-litigate the brainstorm's risk framing in the PRD.** Acceptance criteria and tests still cover the risk; the PRD shape just reflects edit structure.

## Rationale

Phased plans (P1 scaffolding → P2 hardening) are the brainstorm's default shape because they read well on a review. But when the user asks for a combined minimum plan, they are explicitly trading phased rigor for fewer PRs and less orchestrator ceremony. Phase-based grouping then produces stories that all touch the same file — leading to merge churn, story-merge conflicts in `/run-project --swarm`, and redundant file locks.

Edit-locality grouping is the dual optimization: it minimizes story count, minimizes file-lock contention, and produces PRs that a reviewer can evaluate as a single coherent change. The rule is worth codifying because the brainstorm's recommended structure is persuasive — it's easy to carry the P1/P2 split into the PRD by default even after the user has explicitly asked for the combined shape.

Observed during the `gtm-hq-cleanup` session (2026-04-23): brainstorm recommended a two-phase plan (P1: Accounts fixes, P2: depletions filter); user overrode with "one combined, minimum story plan"; correct output was two stories grouped by the two files touched (`accounts-data.ts` and `depletions-filters.tsx`), not by phase.
