---
description: Walk through a list of pending decisions one at a time via AskUserQuestion, never batched.
allowed-tools: AskUserQuestion, Read, Write, Edit, Bash
argument-hint: [free-text description of the decisions to walk through, or path to a queue file]
visibility: public
---

# /decision-queue — Sequential Decision Walkthrough

Forces strict compliance with `decision-queue-one-at-a-time.md` (global policy, soft enforcement). When a session has accumulated 2+ user-facing decisions, invoke this command to walk them one at a time with `AskUserQuestion`, updating working state between answers.

**Input:** $ARGUMENTS

## When to Use

- The model is about to surface 2+ decisions and is tempted to batch them into a single `AskUserQuestion` (or a numbered list in text).
- A skill (`/brainstorm`, `/plan`, `/architect`, `/diagnose`, `/run-project`, `/execute-task`, `/strategize`, `/review-plan`) needs to defer to the user on several separable choices.
- Ad-hoc: the user is mid-task, has multiple open questions, and explicitly asks for a decision queue (`decision queue plz`, `walk me through these one at a time`).

## Rule

Each decision = **one** `AskUserQuestion` call with **one** question. Wait for the answer. Update any working state (plan file, brainstorm.md, PRD, in-memory state, or just an explicit acknowledgement). Then proceed to the next decision.

**Never** batch 2+ decisions into a single `AskUserQuestion` invocation, even though the tool accepts up to 4 questions per call. That capacity is for *disambiguating a single decision* (e.g. "Which DB?" + "Which migration tool?" as a tightly-coupled pair), not for stacking unrelated decisions.

## Process

1. **Parse $ARGUMENTS** — either a free-text description of decisions in scope, or a path to a markdown/json file listing them. If neither, infer from session context (most recent assistant message that surfaced decisions).
2. **Enumerate the queue** internally as a numbered list with: title, context, default recommendation (if any), 2-4 options.
3. **Show the queue header** to the user as a transparency block: `Decision queue (N items): 1. …  2. …  3. …` so they know what's coming.
4. **For each decision in order:**
   a. Brief insight block explaining why this decision is foundational / what it unlocks.
   b. `AskUserQuestion` with exactly one question, 2-4 options, recommended option first with `(Recommended)` suffix.
   c. Wait for the answer.
   d. Update working state — minimum: state in plain text what was decided and how it shapes the next decision. If a plan file / brainstorm.md / PRD exists, persist the answer there.
   e. If the answer materially changes the remaining queue (e.g. user picks "skip the rest", "stop", or an option that obviates downstream questions), re-enumerate before moving on.
5. **After the last decision:** summarize the resolved decisions as a numbered list and confirm next action.

## Examples

**Correct (sequential):**

```
Decision queue (3 items):
  1. Branching strategy
  2. PR splitting
  3. Test coverage scope

[Insight: branching strategy is foundational because…]
AskUserQuestion(Q1) → user picks "new branch off main"
[Update: working on indigo/hq-sync-… off latest main]

[Insight: PR splitting depends on Q1 because…]
AskUserQuestion(Q2) → user picks "single PR"
[Update: one PR for both yellow-removal + copy-prompt]

[Insight: test scope follows from Q2 because…]
AskUserQuestion(Q3) → user picks "vitest only"
[Update: no Playwright; local units + manual UAT]

Resolved:
  1. Branch off main → indigo/hq-sync-no-yellow-copy-prompt
  2. Single PR
  3. vitest + manual UAT
```

**Incorrect (batched):**

```
AskUserQuestion([Q1, Q2, Q3])  ← never do this; even though the schema allows it
```

## Rules

- One `AskUserQuestion` call per decision.
- Recommended option goes first with `(Recommended)` in the label, per `AskUserQuestion` tool conventions.
- Never reference "the plan" if you are in plan mode — the user can't see it. Use `ExitPlanMode` for plan approval, not `AskUserQuestion`.
- If only **one** decision is in scope, don't invoke `/decision-queue` — just ask directly.
- If the user says "stop", "I'll figure it out", or picks an option that ends the queue, stop. Do not force the remaining decisions.
- Persist resolutions in the appropriate working file (plan / PRD / brainstorm.md) when one exists; otherwise just state the resolution in text.

## Related

- Global policy: `core/policies/decision-queue-one-at-a-time.md`
- Counterpart for accepted technical decisions worth not re-litigating: `/adr`
- Counterpart for rejected ideas: `/out-of-scope`
