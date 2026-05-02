---
id: hq-grep-preflight-overloaded-compound-pattern
title: Use compound grep patterns for overloaded terms like "Preflight" when verifying removal
scope: global
trigger: Grep-verifying removal of a named section whose name ("Preflight", "Guard", "Check", "Hook") is reused for other concepts in the same file or repo
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

When grep-verifying that a named section has been removed, NEVER search for the bare name of the section if that name is reused elsewhere in the file for a different concept. Use a compound pattern that disambiguates the specific instance.

Example (brainstorm skill, 2026-04-22):

- WRONG: `grep -n 'Preflight' .claude/skills/brainstorm/command.md`
  - Returns hits for the (removed) Plan-Mode Preflight AND the still-present Repo-run preflight
  - False-positive risk: reviewer sees hits, assumes removal succeeded because "something" is there, or assumes removal failed and re-adds the wrong guard
- RIGHT: `grep -nE 'plan.mode|plan-mode|Plan-Mode Preflight' .claude/skills/brainstorm/command.md`
  - Scoped to the specific instance being removed
  - Zero hits = confirmed removal

Pattern: when the removed section's name is a generic noun reused in the file, grep for the **qualifier + name** together (e.g. `plan-mode.*preflight`, `conflict.*marker.*guard`), not just the name.

## Rationale

Overloaded terms are common in HQ skills because similar mechanisms (guards, checks, preflights, hooks) show up at multiple layers: plan-mode, repo-run, policy, worker, orchestrator. "Preflight" in the brainstorm skill alone refers to at least two independent mechanisms. Grepping the bare term returns a mix of target and non-target hits, producing one of two failure modes:

1. Reviewer assumes the non-target hit is the target — leaves the wrong guard in place, removes or mutates an unrelated one
2. Reviewer gets confused by the mixed results, abandons the grep check, and ships with the orphan intact

The compound pattern costs nothing and eliminates the ambiguity. Composes with `hq-skill-guard-removal-grep-orphan-refs.md` — that rule says "grep after removal," this rule says "use the right pattern for that grep."
