---
id: decision-queue-one-at-a-time
title: Present decisions one question at a time, never batched
scope: global
trigger: when surfacing user-facing questions or decisions via AskUserQuestion, Codex request_user_input, or any structured picker (any skill or ad-hoc)
enforcement: soft
public: true
version: 2
created: 2026-05-08
updated: 2026-05-12
source: session-learning; user-correction
---

## Rule

When a skill or session surfaces user-facing questions or decisions, prefer a clickable/structured picker whenever the runtime exposes one:

- Claude Code: use `AskUserQuestion`.
- Codex: use `request_user_input` when callable and the question can be expressed as 2-3 selectable choices.
- Other runtimes: use the closest structured interactive picker available.

When there are multiple questions or decisions, present them as a **sequential queue** — one structured question call per decision, wait for the answer, update working state (plan file, brainstorm.md, etc.), then ask the next.

**Never** batch 2+ questions into a single `AskUserQuestion`, `request_user_input`, or equivalent call, even if the tool supports multiple questions per invocation.

Applies to: `/brainstorm`, `/plan`, `/deep-plan`, `/architect`, `/diagnose`, `/run-project`, `/execute-task`, `/strategize`, `/review-plan`, and any other skill or ad-hoc moment where the model needs user input on multiple separable choices.

## Examples

**Correct:**

```
[Insight block explaining why Q1 is foundational]
AskUserQuestion(questions=[Q1])
→ user answers
[Update plan/brainstorm with Q1's decision]
[Insight block explaining why Q2 follows]
AskUserQuestion(questions=[Q2])
→ user answers
...
```

Codex equivalent:

```
request_user_input(questions=[Q1])
→ user answers
[Update state]
request_user_input(questions=[Q2])
→ user answers
```

**Incorrect:**

```
AskUserQuestion(questions=[Q1, Q2, Q3, Q4])
request_user_input(questions=[Q1, Q2])
```

Some tools allow multiple questions per call. Hard cap at 1 in HQ.

## Rationale

Stated explicitly by the user during a deep planning brainstorm session on 2026-05-08, then promoted to a global HQ setting at user request later in the same session.

The user's reasoning, as observed: each decision benefits from a focused educational insight block in context (kept by HQ's active output style) and from seeing the *previous* decisions land before evaluating the next. Batching forces the user to weigh 4 unrelated choices simultaneously, which:

1. Loses the per-decision insight-block scaffolding (you can only fit one short rationale into a batched form, or it bloats unmanageable).
2. Prevents cascading clarifications — Q3's right answer often shifts based on what was decided at Q1 and Q2; batching freezes that interaction.
3. Encourages defensive multi-select choices (the user picks "all that might apply" rather than commit to one) when they would have picked decisively given each in isolation.
4. Produces worse downstream artifacts (PRD, plan files, brainstorms) because the rationale chain isn't visible in the conversation transcript.

Sequential one-at-a-time questioning is slower per-decision but produces decisively better decisions and richer working artifacts.

## Relationship to `brainstorm-use-decision-mode`

This policy is **additive** to [brainstorm-use-decision-mode](brainstorm-use-decision-mode.md):

- That policy says: `/brainstorm` MUST use `AskUserQuestion` (not markdown numbered lists).
- This policy says: `AskUserQuestion`, Codex `request_user_input`, or any equivalent picker MUST be invoked one question per call (not batched), in any skill.

Together: the harness's interactive picker is the canonical input surface, and it's always used one question at a time.

## Hook gating

No hook currently enforces this — it's a soft policy. If a hook is later added to count `questions[]` length and warn on batched calls, that hook can be installed without changing this rule body.
