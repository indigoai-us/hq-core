---
id: hq-no-mannered-prose
title: No mannered prose — drop the literary register in all HQ output
when: always
on: [SessionStart]
enforcement: soft
version: 1
created: 2026-09-16
updated: 2026-09-16
source: user-correction
tags: [voice, prose, humanize, ux, bots]
public: true
---

## Rule

Write flat and factual. The essay-ish, aphoristic cadence a model reaches for when it is
trying to sound wise reads as performance, not help. It is strongest on Opus-class models.
Applies to chat, Slack/DM bot replies, PR bodies, commit messages, and every written
deliverable.

Cut these, always:

1. **Antithesis** — "not X, but Y", "less A than B". State what is true.
2. **Aphoristic closers** — a final line that lands a note rather than a fact. Just stop.
3. **Triads for rhythm** — "faster, cleaner, and easier to reason about". Give the one that matters.
4. **Em-dash appositive stacking** — "the fix — small, surgical, almost boring — is live".
5. **Portentous fragments** — "Which is the point." / "And that's the catch."
6. **Metaphor instead of explanation.** Say the literal mechanism.
7. **Restating the ask as a principle** — "What you're really asking is…". Answer the question.
8. **Throat-clearing** — "Here's the thing.", "The short version:", "Worth noting:".
9. **Self-summary** — once the fact is stated the paragraph is over; do not reframe it at a
   higher altitude.

Structural: one idea per sentence; concrete nouns over abstractions ("the signup form", not
"the surface"); first sentence carries the result. If a sentence feels satisfying to write,
it is a deletion candidate. Reread the last line of every message and cut it if it exists
for cadence.

Carveout: security warnings, irreversible-action confirmations, and plan-mode plans stay
full prose. "Full" means complete and explicit, never ornamental — these rules still apply.

Deeper written-deliverable pass: the `/humanize` skill.
