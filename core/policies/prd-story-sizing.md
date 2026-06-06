---
id: prd-story-sizing
title: PRD Story Complexity Budget
scope: command
trigger: /prd story generation
when: /prd
on: [UserPromptSubmit]
enforcement: soft
public: true
---

## Rule

Every user story in a PRD must have a complexity score computed as:

**Score = (acceptance criteria count x 1) + (declared files count x 2)**

If score exceeds **20**, the `/prd` command must:
1. Warn the user with the score and recommend splitting
2. Offer auto-split strategies (tab group, entity boundary, API/UI separation)
3. If the user declines, add `"model_hint": "opus"` to the story

Stories with **12+ acceptance criteria** should almost always be split regardless of file count.

## Rationale

During `{company}-{your-project}-v4`, oversized stories (US-003: 12 ACs/7 files = score 26, US-004: 13 ACs/8 files = score 29) caused context overruns in sub-agents, requiring manual recovery and stalling execution. Smaller stories complete reliably in a single AI session — the core Ralph loop invariant.
