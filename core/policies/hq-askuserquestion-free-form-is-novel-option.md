---
id: hq-askuserquestion-free-form-is-novel-option
title: Free-form answer to AskUserQuestion is a novel option, not a rejection
scope: global
trigger: any command/skill that presents choices via AskUserQuestion and receives free-form text that does not map to a listed option
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

When the user answers an `AskUserQuestion` with free-form text that does not select any of the presented options, treat the text as a legitimate novel fourth (or Nth) approach — NOT as a non-answer that warrants re-asking.

Behavior:
1. Parse the free-form text for the user's intent — they are proposing an alternative the question did not anticipate.
2. Integrate that alternative into the downstream plan (e.g. add it as a new user story, accept it as the chosen approach, or treat it as the explicit override).
3. Do NOT re-prompt with the same question set. Re-asking signals the model missed the user's actual input and wastes a turn.
4. If the free-form answer is genuinely ambiguous (not just "none of the above"), ask a targeted clarifying question about that alternative — not the original multi-choice list.

## Rationale

In a recent `/plan` session, the AskUserQuestion offered three story archetypes and the user replied "build prompts for me to put into hq sessions." That text was not a rejection of the three options — it was the decisive differentiator of US-015 and the actual deliverable the user wanted. Treating it as "no answer selected" and re-asking would have stalled the planning loop and frustrated the user.

AskUserQuestion is a decision tool, not a forced-choice poll. The free-form fallback exists precisely because the model can't enumerate every valid option in advance. When the user uses that fallback, the correct next move is to accept their framing and proceed.

## Anti-patterns

- Re-presenting the same option list after a free-form reply → signals the model didn't read the answer
- Paraphrasing the user's free-form text back into one of the original options without confirming → loses their intent
- Treating free-form text as "no decision yet" and waiting for a numbered pick → blocks the session indefinitely
