---
id: hq-classifier-own-labels-single-source
title: Classifiers own their labels — never duplicate bucketing logic in the display shell
scope: global
trigger: UI refactor, dashboards, data-layer + component refactors, bucketing/tier/status logic
enforcement: hard
public: true
version: 1
created: 2026-04-20
updated: 2026-04-20
source: session-learning
---

## Rule

When a classifier (tiering, bucketing, status, cohort assignment) is computed in the data layer, the **data layer must own the labels too**. Never let a display shell (component, page, wrapper) re-compute the same classification with its own thresholds or its own label map.

Concretely:

- If `data/lib/accounts.ts` returns `status: "active" | "at-risk" | "churned"` using thresholds 14/30/60 days, the React component rendering those accounts MUST consume that field verbatim. It must NOT re-bucket with its own 30/60/90 thresholds or its own label set.
- The classifier lives in ONE module. The component imports the label (and any display metadata like chip color) from that module or from a sibling `labels.ts` that the classifier also imports.
- If the shell needs a display-only transformation (e.g. title-casing, truncation, a color palette), that is a pure render concern — it must not change *which bucket* a row lands in.

When you discover duplicated classification logic, delete the shell copy and make the data layer authoritative in the same commit. Do not "leave both in place until we unify later."

## Rationale

Duplicated classifiers drift silently. Two threshold sets (14/30/60 in data, 30/60/90 in shell) produce contradictory UI: the data layer says "active," the pill says "at-risk," and neither log line nor test catches it because both are internally consistent.

The root cause is almost always that the shell was built first (with its own ad-hoc thresholds), the data layer grew a proper classifier later, and nobody deleted the shell copy. The fix is cheap (delete + re-import) but requires discipline: when you see duplicate bucketing, fix it then, not "next sprint."

