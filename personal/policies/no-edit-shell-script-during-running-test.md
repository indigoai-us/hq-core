---
id: personal-no-edit-shell-script-during-running-test
title: Do not edit a shell script while it is executing
when: test || shell || bash
on: [PreToolUse, AssistantIntent]
enforcement: soft
version: 1
created: 2026-08-20
updated: 2026-08-20
source: task-completion
learned_from: T-20260820-131656-workflow-runner-added-resume
public: false
---

## Rule

Do not edit a shell script while a running test or process is executing that
same file. Wait for the process to finish, then rerun the test before treating
an unrelated shell syntax error as a defect in the script.

## Rationale

Bash can read a script incrementally by byte offset. An in-flight edit can move
subsequent content and produce a misleading parse error at an unrelated line.

