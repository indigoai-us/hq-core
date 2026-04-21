---
id: prd-files-match-acs-for-swarm
title: PRD files[] must match ACs before swarm execution
scope: command
trigger: /run-project, /prd
enforcement: soft
created: "2026-04-02"
---

## Rule

Before launching `/run-project` with `--swarm`, verify that each story's `files[]` array includes ALL files mentioned in its acceptance criteria. Swarm mode uses `files[]` for overlap detection — missing declarations cause silent merge conflicts during cherry-pick.

