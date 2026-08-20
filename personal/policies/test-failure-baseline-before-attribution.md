---
id: personal-test-failure-baseline-before-attribution
title: Establish a baseline before attributing a test failure
when: test || regression || failure
on: [PreToolUse, PostToolUse, AssistantIntent]
enforcement: soft
version: 1
created: 2026-08-20
updated: 2026-08-20
source: task-completion
learned_from: T-20260820-131656-workflow-runner-added-resume
public: false
---

## Rule

Before attributing a failing suite to a feature change, run the relevant suite
against the recorded baseline (normally `origin/main`) under comparable
conditions. Report failures that reproduce there as pre-existing or flaky until
evidence shows otherwise.

## Rationale

Feature-branch failures can be caused by machine-load flakes or broken fixtures
that already fail on the baseline. A baseline run preserves accurate regression
ownership and directs fixes to the correct work item.

