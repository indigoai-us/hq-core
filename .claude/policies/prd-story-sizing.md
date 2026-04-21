---
id: prd-story-sizing
title: PRD Story Complexity Budget
scope: command
trigger: /prd story generation
enforcement: soft
---

## Rule

Every user story in a PRD must have a complexity score computed as:

**Score = (acceptance criteria count x 1) + (declared files count x 2)**

If score exceeds **20**, the `/prd` command must:
1. Warn the user with the score and recommend splitting
2. Offer auto-split strategies (tab group, entity boundary, API/UI separation)
3. If the user declines, add `"model_hint": "opus"` to the story

Stories with **12+ acceptance criteria** should almost always be split regardless of file count.

