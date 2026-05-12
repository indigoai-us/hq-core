---
id: hq-cmd-brainstorm-deep-mode-suspends-batching
title: /brainstorm --deep suspends 1-question-max batching — depth-first interview
scope: global
trigger: /brainstorm invoked with --deep flag, or user explicitly asks for "grill-style" / "one question at a time" interview
enforcement: soft
tier: 2
public: true
version: 1
created: 2026-04-30
updated: 2026-04-30
source: discover/skills@b843cb5e
learned_from: discover/skills@b843cb5e
---

## Rule

When `/brainstorm --deep` is invoked, the skill's normal **"1 question max — batch all missing directional info into one AskUserQuestion call"** rule (Step 3, Light Interview) is **suspended**.

Replace it with depth-first one-question-at-a-time:

1. Each `AskUserQuestion` call presents **exactly one question** (one item in the items array).
2. Walk the decision tree depth-first — resolve each branch before opening the next.
3. For each question, **state the recommended answer with reasoning** before asking. The question is "do you agree, or pick a different option" — not "what should we do?"
4. **If a question can be answered by exploring the codebase, explore the codebase instead** — never ask the user to verify a claim that `Read` / `Grep` / `Glob` would resolve.
5. Continue until the decision tree is fully resolved. There is no question cap in deep mode.
6. The HQ-wide `hq-askuserquestion-max-4-batch-rounds` policy still applies — each individual call has ≤4 items. Deep mode uses 1 item per call by design, so the constraint is never tested.

## Rationale

The default light-interview shape (1 batched call, ≤4 items) is right when the user already knows the directional answer and only needs to ratify a pick. It's the wrong shape when the user genuinely doesn't know what they want and the value of brainstorm comes from being grilled — branching decisions where answer N+1 depends on answer N can't be batched.

Pattern source: `mattpocock/skills` `productivity/grill-me/SKILL.md` — "ask the questions one at a time, walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer."

This carve-out is mode-specific and explicit. The light-interview default is unchanged for the common case — `/brainstorm <idea>` without `--deep` keeps the 1-question-max batching.

## Off-switch

`/brainstorm --light` (or just `/brainstorm` without `--deep`) restores the default batched single-call behavior. The carve-out applies only inside the `--deep` invocation.

## Related

- `brainstorm-use-decision-mode` — AskUserQuestion (not markdown lists) is still required for every user-facing choice in deep mode
- `hq-askuserquestion-max-4-batch-rounds` — the per-call ≤4 constraint stays; deep mode uses 1
- `hq-askuserquestion-free-form-is-novel-option` — free-text "Other" option is still automatic
- `hq-cmd-run-project-no-askuserquestion-stories-in-ralph-mode` — sibling pattern: mode-specific suspension of a default rule
