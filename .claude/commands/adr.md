---
description: Capture an Architectural Decision Record. Three-condition gate (hard-to-reverse + surprising + result-of-trade-off). Sequential numbering. Code-bound ADRs go in repo; HQ-managed project decisions go in company knowledge.
allowed-tools: Read, Grep, Glob, Bash, Write, Edit, AskUserQuestion
argument-hint: "[company] [repo|hq] <one-line decision summary>"
visibility: public
---

# /adr — Architectural Decision Record

Capture a decision so future-you (and future-Claude) doesn't re-litigate it.

**Input:** $ARGUMENTS

## Three-condition gate

Only write an ADR when **all three** are true:

1. **Hard to reverse** — cost of changing your mind later is meaningful.
2. **Surprising without context** — a future reader will look at the code/config and wonder "why on earth did they do it this way?"
3. **Result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons.

If a decision is easy to reverse → skip it; you'll just reverse it. If it's not surprising → nobody will wonder. If there was no real alternative → there's nothing to record beyond "we did the obvious thing."

The skill enforces this gate: it asks the three questions before writing. If any answer is no, it offers to skip or downgrade to a `CONTEXT.md` glossary entry instead.

## Steps

1. Load the adr skill from `.claude/skills/adr/SKILL.md`.
2. Resolve company + scope (`repo` for code-bound; `hq` for HQ-managed project decisions).
3. Run the three-condition gate via `AskUserQuestion`. Block if not all three.
4. Determine target directory:
   - `repo` scope → `<repo>/docs/adr/` (lazy-create)
   - `hq` scope → `companies/{co}/knowledge/adrs/` (lazy-create)
5. Scan target dir for highest existing `NNNN-` prefix; increment.
6. Walk the user through 1–3 sentences of context + decision + reasoning.
7. Offer optional sections (Status, Considered Options, Consequences) only when they add value.
8. Write `NNNN-slug.md`. If new domain terms surfaced, offer to also update `CONTEXT.md`.

## Cross-references

- `/brainstorm`, `/prd`, `/architect`, `/diagnose` Phase 6 — all hand off to `/adr` when a decision should be locked down.
- `/out-of-scope` is the sibling for *rejected feature requests* (vs. `/adr` for *accepted technical decisions*).
- Pattern source: `mattpocock/skills` `grill-with-docs/ADR-FORMAT.md` (`repos/public/skills/skills/engineering/grill-with-docs/ADR-FORMAT.md`).
