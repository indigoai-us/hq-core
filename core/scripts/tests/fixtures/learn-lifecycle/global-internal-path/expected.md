---
id: hq-session-state-read-before-resume
title: Read session state before resuming a lane
when: resume && lane
on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]
enforcement: hard
public: false
status: active
version: 1
created: 2026-10-07
updated: 2026-10-07
source: user-correction
notes: public false because the Rule names an HQ-internal path
---

## Rule

ALWAYS read workspace/sessions/{id}/pool/handoffs.jsonl before resuming a lane, and skip stories it records as done.

## Rationale

The handoff ledger is the only record of finished stories, so reading it first prevents duplicate commits.

## Provenance

Reported by Jane Doe on 2026-09-12 in PR #412.
