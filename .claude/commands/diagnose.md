---
description: Disciplined diagnosis loop for hard / non-deterministic / performance bugs — build feedback loop FIRST, then reproduce → hypothesise → instrument → fix → regression-test
allowed-tools: Read, Grep, Glob, Write, Edit, Bash, Agent, AskUserQuestion
argument-hint: "[company] <bug description or symptom>"
visibility: public
---

# /diagnose — Feedback-Loop-First Debugging

For hard bugs, performance regressions, and intermittent failures where the dominant problem is **"I can't reliably reproduce or measure this."**

**Input:** $ARGUMENTS

## When to use which

| Situation | Skill |
|---|---|
| Bug reproduces reliably; you don't know the root cause | **`/investigate`** — Iron Law: no fixes before root cause |
| Bug is intermittent, flaky, env-specific, or "sometimes wrong" | **`/diagnose`** (this) — build a deterministic feedback loop first |
| Performance regression with no signal | **`/diagnose`** — establish baseline measurement before hypothesising |
| Tests pass locally, fail in CI | **`/diagnose`** — feedback loop must run in the failing env |
| Code is fine, design is the problem | **`/architect`** |

`/investigate` and `/diagnose` are siblings, not duplicates. Use one or the other; if a `/diagnose` session reveals a clean repro and the cause is still unknown, hand off to `/investigate`.

## Steps

1. Load the diagnose skill from `.claude/skills/diagnose/SKILL.md`.
2. Resolve company context (manifest lookup, cwd inference — same pattern as `/investigate` and `/brainstorm`).
3. Execute the 6 phases:
   - **Phase 1 — Build a feedback loop** (the skill's heart; spend disproportionate effort here)
   - **Phase 2 — Reproduce** using the loop
   - **Phase 3 — Hypothesise** (3–5 ranked, falsifiable predictions)
   - **Phase 4 — Instrument** with tagged probes, one variable at a time
   - **Phase 5 — Fix + regression test** at the correct seam (or note absence of seam)
   - **Phase 6 — Cleanup + post-mortem** (remove tagged debug logs, document the winning hypothesis)
4. Save the diagnostic report to `workspace/reports/{slug}-diagnose.md`.
5. If the cleanup step reveals an architectural smell (no good test seam, tangled callers), suggest `/architect` for follow-up.
6. After verified fix: suggest `/learn` to capture the failure-mode pattern (cross-tenant if applicable).

## Cross-references

- HQ `/investigate` — root-cause-first when bug reproduces. `/diagnose` is the reproducibility-first sibling.
- HQ `/tdd` — uses Phase 5's regression test as a starting point for full red-green-refactor coverage.
- HQ `/architect` — Phase 6's "what would have prevented this" handoff.
- Pattern source: `mattpocock/skills` `/diagnose` (`repos/public/skills/skills/engineering/diagnose/SKILL.md`).
