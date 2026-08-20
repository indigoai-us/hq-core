---
id: personal-workflow-runner-off-contract-reformat
title: Repair workflow-agent output by reformatting, not rerunning
when: workflow || workflow-runner || json || schema
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

For Workflow runner agents that return prose instead of their declared JSON
contract, use at most one bounded reformat pass before considering a rerun. The
repair pass must use no tools, must not invent an outcome absent from the reply,
must choose the blocked or failing interpretation when evidence is ambiguous,
and its result must pass the same schema validation as a first-pass reply.

## Rationale

An agent can complete its work while losing only the response envelope after
compaction. A constrained reformat recovers that evidence without duplicating
work; schema validation prevents malformed or invented state from advancing the
workflow.

