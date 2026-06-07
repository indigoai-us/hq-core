---
id: hq-verify-shared-files-after-parallel-agents
title: Verify shared files after parallel agent edits
scope: global
trigger: parallel agent execution editing same file
when: parallel
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
version: 1
created: 2026-03-26
updated: 2026-03-26
source: success-pattern
public: true
---

## Rule

When 3+ parallel agents all edit the same file (e.g., registry.yaml, package.json, INDEX.md), always read the final file after all agents complete and verify: no duplicate entries, consistent formatting, no merge artifacts. Append-only edits to the same section typically succeed, but each agent can't see the others' changes.

## Rationale

Gemini design team setup: 3 parallel agents each added a worker to registry.yaml. All succeeded cleanly because edits were append-only, but any of them could have produced duplicates or formatting breaks since they operate independently. Post-verification caught this as clean — but the pattern needs enforcement for cases where it isn't.
