---
id: hq-askuserquestion-max-4-batch-rounds
title: AskUserQuestion max 4 per call — batch larger interview sets into rounds
scope: global
trigger: any command/skill/session that presents more than 4 questions to the user via AskUserQuestion in a single interview phase
enforcement: hard
tier: 1
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: session-learning
---

## Rule

`AskUserQuestion` accepts a maximum of **4 questions per call**. When an interview, brainstorm, or plan step lists more than 4 mandatory questions:

1. **Batch into rounds of 4 or fewer.** Never attempt a single `AskUserQuestion` call with 5+ questions — the call will fail or the extra questions will be silently dropped.
2. **Order rounds by architectural impact.** Schema-shaping, data-model, and boundary-defining decisions go in the first round so the user can sanity-check the big shape before drilling in. Mechanical details (CHECK constraints, flip thresholds, cron cadences, copy variants) go in later rounds.
3. **Preserve question independence within a round.** The 4 questions inside a single call should be answerable independently; cascading dependencies belong in separate rounds so later questions can adapt to earlier answers.

## Rationale

Observed during the `holler-role-scoped-permissions` brainstorm: the skill produced an 8-question mandatory interview list, and a single-shot AskUserQuestion attempt with all 8 questions would have either errored or truncated. Batching into two rounds of 4 — schema/boundary decisions first, CHECK/threshold details second — let the user correct a foundational shape decision (role vs. tier primitive) before being asked about implementation-level constraints that would have been reshaped by that answer.

The 4-question cap is a tool-surface constraint, not a taste preference — hence hard enforcement. The rationale for the ordering heuristic (impact-first) is separate: answering mechanical questions against the wrong architectural shape wastes the round and forces a re-interview.

## Related

- `brainstorm-use-decision-mode` — mandates AskUserQuestion for `/brainstorm` user-facing choices
- `hq-askuserquestion-free-form-is-novel-option` — how to handle free-form answers that fall outside the presented options
- `hq-askuserquestion-headless-gate` — headless-mode gating for AskUserQuestion calls
- `prd-minimum-questions` — the 10-question PRD floor that typically requires 3 rounds to cover
