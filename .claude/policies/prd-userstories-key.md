---
id: prd-userstories-key
title: PRD must use userStories key (not stories)
scope: command
trigger: /prd, prd.json creation
enforcement: hard
created: 2026-03-30
---

## Rule

PRDs MUST use `"userStories"` as the array key for stories (not `"stories"`). Every story object MUST include `"passes": false`. `run-project.sh` validates both at lines 442-462 and hard-exits if either is missing.

