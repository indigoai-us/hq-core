---
id: prd-minimum-questions
title: PRD skill must reach a minimum of 10 interview questions
scope: command-scoped
trigger: /prd, prd skill, SKILL.md prd execution
when: prd || plan
on: [SessionStart]
enforcement: hard
public: true
tags: [planning]
---

## Rule

The prd skill interview runs on the grilling engine and MUST reach at least 10 questions, counted from the engine count object written to `prd.json` `metadata.interview` as `asked + skipped_known`.

- `asked` counts each question put to the user (one AskUserQuestion call per question). Pushback follow-ups do not count. Premise-challenge sub-questions count as 1 total. Operational questions asked after the interview (Live Path Watch) count.
- `skipped_known` counts answers loaded from a brainstorm.md with recorded answer ids, and answers fully settled by a pre-fill hint. These questions are not re-asked as confirmations.
- `skipped_fact` (lookups such as `project_type`) does not count.

The asked questions MUST span at least 2 of the 3 tiers (strategic, architecture, quality), read from `metadata.interview.by_tier`.

If the user ends the interview early, or the total is below 10, warn "{N}/10 answered" with N = `asked + skipped_known`, and continue.

Check: `bash core/scripts/prd-interview-check.sh <prd.json>`. Test: `bash core/scripts/tests/prd-minimum-questions.test.sh`.

## Rationale

Shallow PRDs cause mid-execution story rewrites, the most expensive failure in the execution loop. A worker that finds missing requirements at story 4 of 7 forces a PRD revision and re-execution of completed stories. The interview is the cheapest quality gate.

The minimum of 10 was calibrated against earlier PRD sessions: projects with fewer than 10 interview data points produced stories with ambiguous acceptance criteria, missing error handling, and scope creep during execution. Answers recorded in a brainstorm are interview data points, so they count toward the minimum instead of being asked a second time.
