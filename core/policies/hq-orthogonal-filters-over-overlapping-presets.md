---
id: hq-orthogonal-filters-over-overlapping-presets
title: Prefer orthogonal filters over N presets derived from the same composite score
scope: global
trigger: dashboard UX, filter design, saved-view presets, account/lead prioritization UIs
when: dashboard || filter
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-20
updated: 2026-04-20
source: session-learning
---

## Rule

When designing filters for a prioritization UI (rep accounts, leads, tasks, tickets), prefer **orthogonal filter axes** over **N preset views that all derive from the same composite score**.

Concretely:

- **Bad:** "Top accounts," "Needs attention," "At risk," "High value" — four presets that all sort by the same composite score and surface roughly the same top-20 rows with different labels.
- **Good:** Two orthogonal axes — e.g. **action cohort** (recently-touched / due-to-touch / stale) × **status facet** (active / at-risk / churned) — giving the user a 3×3 or 2×N matrix where each cell answers a distinct question.

Heuristics:

1. If two presets return >50% overlapping rows when applied to real data, they are not actually distinct filters — pick one and delete the others.
2. Users who cannot articulate the difference between two filters in one sentence will not use either confidently. Test filter distinctness with real users, not engineers who wrote the formula.
3. Composite scores (one number summarizing many inputs) are great for *sorting* but terrible for *filtering*. If you need multiple entry points into a dataset, expose the component inputs, not N variations of the sum.
4. When in doubt, start with 2 axes × 2–3 values each. Expand only when a user requests a view the current axes cannot express.

## Rationale

In April 2026 a reps dashboard shipped with 4 preset views ("VIP churn risk," "Needs refresh," "Top priority," "Stale accounts"). All four were ranked by the same composite score (`0.4 * daysSinceTouch + 0.3 * depletionPressure + 0.3 * vipValue`). Rep users couldn't tell them apart — each preset surfaced the same top 20 accounts in a slightly different order. Replacing the 4 presets with a 3×3 matrix of **action cohort × status facet** gave reps distinguishable, actionable cells and cut confused support requests to zero.

The underlying pattern: a composite score collapses a high-dimensional space to one axis. N presets on that axis are N arbitrary slices of the same line — they look different on paper and feel identical in use. Orthogonal filters expose dimensions the user can reason about independently.
