---
description: Surface architectural friction and propose deepening opportunities — modules scored by deletion test, leverage, locality. Refactor candidate list, not direct edits.
allowed-tools: Read, Grep, Glob, Bash, Agent, Write, Edit, AskUserQuestion
argument-hint: "[company] [path]"
visibility: public
---

# /architect — Deep-Module Analysis

Find places in a codebase where the architecture is the bug. Output is a ranked list of **deepening opportunities** with leverage and locality framing — not direct edits.

**Input:** $ARGUMENTS

## When to use

| Trigger | This skill |
|---|---|
| "This codebase is hard to change" | ✅ |
| "We have ten tiny modules; tests are everywhere; bugs hide in the call graph" | ✅ |
| "Help me find what to refactor" | ✅ |
| "/diagnose Phase 6 said the test seam is missing" | ✅ (continuation of `/diagnose`) |
| "Fix the bug" | ❌ — use `/investigate` or `/diagnose` |
| "Implement this PRD" | ❌ — use `/run-project` |

## Steps

1. Load the architect skill from `.claude/skills/architect/SKILL.md`.
2. Resolve company + target path. Default target: cwd if inside a repo; otherwise ask.
3. Read the target repo's `CONTEXT.md` (domain glossary) and `docs/adr/` (architectural decisions) if present.
4. Spawn parallel `Agent subagent_type=Explore` calls to walk distinct top-level slices of the target. Each agent reports friction points using the architecture glossary (Module / Interface / Implementation / Depth / Seam / Adapter / Leverage / Locality).
5. Score and rank deepening opportunities. Apply deletion test, leverage / locality heuristics, and the one-adapter-vs-two-adapter rule.
6. Present the candidate list via `AskUserQuestion`. User picks which to explore.
7. For each picked candidate: drop into a grilling-style design conversation. Update `CONTEXT.md` lazily as terms crystallize. If a candidate is rejected with a load-bearing reason, offer to record an `/adr` so future architecture passes don't re-suggest it.
8. Save the candidate list to `workspace/reports/{slug}-architect.md` with status (explored / declined / pending) per candidate.

## Outputs

- `workspace/reports/{slug}-architect.md` — ranked candidate list with file refs, deletion-test outcome, leverage/locality scoring, and decision per candidate.
- Lazy in-place updates to `<repo>/CONTEXT.md` if new domain terms surfaced.
- Optional `/adr` stubs for rejected candidates that would otherwise re-surface.

## Cross-references

- `/review --architect-pass` — same heuristics, narrower scope (changed files only); use during pre-PR review.
- `/diagnose` Phase 6 — hand-off entry point when "no good test seam" is the real story.
- `/adr` — capture decisions that should not be re-litigated.
- Pattern source: `mattpocock/skills` `improve-codebase-architecture` (`repos/public/skills/skills/engineering/improve-codebase-architecture/SKILL.md`).
