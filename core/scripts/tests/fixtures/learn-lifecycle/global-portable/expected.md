---
id: hq-verify-backup-before-destructive-migration
title: Verify a restorable backup before a destructive migration
when: migration && (drop || truncate)
on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
status: active
version: 1
created: 2026-10-07
updated: 2026-10-07
source: success-pattern
---

## Rule

ALWAYS confirm a restorable backup exists before running a migration that drops or truncates data.

## Rationale

A dropped table cannot be recovered without a backup, and confirming the backup costs one command.
