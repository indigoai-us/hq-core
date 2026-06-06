---
id: hq-no-parent-import-from-child-component
title: Never import parent-shell modules from a child component — duplicate small utilities locally
scope: global
trigger: React/TS refactors, component extraction, shared utility/palette/label extraction
when: .tsx || refactor
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
public: true
version: 1
created: 2026-04-20
updated: 2026-04-20
source: session-learning
---

## Rule

A child component MUST NOT import a module from its parent shell (the component that renders it). That creates a circular import graph — `Parent.tsx → Child.tsx → Parent.tsx` — which at best produces `undefined` exports at module-eval time and at worst breaks HMR and production builds in opaque ways.

When a child needs a utility that currently lives in its parent (a chip palette, a label map, a tiny helper), choose ONE of:

1. **Duplicate the small map locally in the child.** A 10-line `const CHIP_COLORS = {...}` duplicated in two files is cheaper than a circular import. Delete the parent copy if the parent no longer needs it after extraction.
2. **Hoist the utility to a sibling module.** Create `palette.ts` / `labels.ts` at a level that is a parent of both users, and have both the original parent and the child import *down* from it. No component imports sideways or up.
3. **Pass the utility as a prop** if the parent has state that drives the mapping. This preserves a one-way dataflow and keeps the child dependency-free.

Never: "I'll just import `{ CHIP_COLORS } from './Parent'` from inside `Child.tsx`." That is the forbidden shape.

## Rationale

Circular imports are silent until they aren't. Modern bundlers (Vite, Next.js, Webpack) tolerate many cycles by resolving one side to `undefined` during the first evaluation pass, so your code "works" locally if the consumer only reads the binding inside a function body (after the module graph settles). But:

- Any top-level read (`const X = Parent.CHIP_COLORS`) crashes in production.
- HMR order becomes non-deterministic — one file edit swaps cleanly, the next full-reloads.
- Tree-shaking breaks — the cycle is retained in the final bundle even if one side is unused.
- Codemods and static analysis (e.g. dependency graphs, orphan detection) produce misleading output.

The April 2026 incident: a reps dashboard extracted an `<AccountChip>` child out of `<AccountsTable>`, and the child imported `CHIP_COLORS` back from the table to preserve the existing palette. The dev build succeeded; the production Vercel build succeeded; the page rendered blank chips in prod because the circular read evaluated to `undefined`. Fix: 10-line palette duplicated locally in `AccountChip.tsx`. Total diff: +10 / -0. Debug cost: ~40 minutes.

The principle generalizes: **data flows one way through a component tree — imports must too.** When tempted to import upward, duplicate or hoist instead.
