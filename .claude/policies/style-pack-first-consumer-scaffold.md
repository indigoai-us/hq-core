---
id: style-pack-first-consumer-scaffold
title: Scaffold shared style-packs at knowledge/public/design-styles/ as Story 1 of the first-consumer PRD
scope: global
trigger: PRD introduces a new visual/motion vocabulary intended to be reused across surfaces
enforcement: soft
public: true
version: 1
created: 2026-04-16
updated: 2026-04-16
source: session-learning
---

## Rule

When a PRD introduces a cinematic treatment, design language, or motion system that will plausibly be reused by sibling surfaces (other apps within the same company, or cross-company brand moments), do not inline the primitives into the consumer repo. Instead, structure the PRD so that:

1. **Story 1** scaffolds the pack at `knowledge/public/design-styles/<pack-id>/` with `pack.yaml`, `tokens.css`, `keyframes.css`, `components/`, `scenes/` (if WebGL), and a `README.md`, and registers the pack in `knowledge/public/design-styles/registry.yaml`.
2. **Story 2** populates the primitive component library inside the pack.
3. The consumer repo's `design.md` declares `style-pack: <pack-id>`; consumer stories import from the pack rather than defining primitives locally.

This applies even when there is only one consumer at PRD time — the scaffolding cost is low and the extraction cost later is high.

## Rationale

Inlining `PrismBeam`, `LightDust`, `PhaseMachine`, etc. into `repos/private/hq-onboarding/src/components/effects/` would have meant re-extracting them across three repos later, with inevitable drift. Pack-first structure preserves design consistency from day one and matches the existing `design.md` + registry resolution pattern that dev-team workers already consume.
