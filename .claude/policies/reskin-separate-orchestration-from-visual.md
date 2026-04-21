---
id: reskin-separate-orchestration-from-visual
title: When reskinning a design, separate orchestration patterns from visual execution
scope: global
trigger: PRD or design task adapts motion/UX patterns from a reference implementation
enforcement: soft
public: true
version: 1
created: 2026-04-16
updated: 2026-04-16
source: session-learning
---

## Rule

When adapting a reference implementation (another site, app, or codebase) into a new visual direction, explicitly split the adaptation into two columns before drafting acceptance criteria:

- **Orchestration patterns to port verbatim** — phase machines, sessionStorage gating, reduced-motion fallbacks, crossfade timing, lazy-scene loading, reveal sequences. These are the structural invariants that make the feel work.
- **Visual vocabulary to replace** — palette, geometry, particle effects, texture, typography, shaders. These express the target brand, not the reference.

Record the split as a translation table in the plan/PRD (columns: "Reference element" → "Our execution"). Acceptance criteria then reference the orchestration pattern by name and the visual treatment by token, making it legible which decisions are borrowed vs. owned.

