---
id: no-shared-skill-extraction-touching-5-files
enforcement: hard
public: true
scope: global
tags: [skills, refactor, abstraction]
created: 2026-04-15
provenance: user-correction
---

## Rule

NEVER extract a shared skill that requires editing 5+ existing files to wire up. When extending behavior across multiple commands/skills, prefer layered independent additions (policy + command + skill edit) over shared extraction. Accept duplicated pattern tables as simpler than shared dependencies.

## Rationale

Shared extraction at this scale produces fragile coupling — every consumer must be edited in lockstep, and a regression in the shared module breaks every caller at once. Layered additions keep blast radius contained. The duplication is cheaper than the maintenance tax of a shared boundary that crosses 5+ owners.
