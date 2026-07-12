---
id: hq-fix-root-cause-not-symptoms
title: Fix root causes, never mask errors
when: bug || debug || /investigate
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
tier: 1
version: 1
created: 2026-04-02
updated: 2026-04-02
source: user-correction
public: true
---

## Rule

NEVER fix a bug by hiding or masking the error. When investigating a failure, always trace to the root cause and fix the actual problem — not just improve how the error is displayed.

Adding error handling UI (retry buttons, better error messages) is necessary but NOT sufficient. If the underlying API/query/service is failing, fix WHY it fails. A "fix" that only improves error presentation while the root cause persists is not a fix.

When debugging:
1. Identify the root cause first
2. Fix the root cause
3. THEN improve error handling/UI as a defense-in-depth measure

## Rationale

During the conversation-details sidebar investigation (2026-04-02), PR #2998 added a `response.ok` guard to `useConversationDetails` — improving error display in the UI. But this didn't fix the actual bug: the PostgREST queries were silently returning `{ data: null, error: {...} }` and the route was passing `null` through as `{ success: true }`. The error handling PR was necessary but would have left the root cause unfixed if accepted as the sole fix.
