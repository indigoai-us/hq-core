---
id: hq-parallel-batch-block-cancels-writes
title: A blocked tool call cancels its whole parallel batch — re-verify writes against disk
scope: global
trigger: A PreToolUse hook blocks one call inside a parallel tool batch that also contains Write/Edit calls
enforcement: hard
public: true
version: 1
created: 2026-05-29
updated: 2026-05-29
source: session-learning
---

## Rule

NEVER: trust "File created successfully" replays after a PreToolUse hook blocks one call in a parallel tool batch — the block cancels the WHOLE batch including Writes. Re-verify artifacts against disk before continuing.

## Rationale

When several tool calls are issued in a single parallel batch and a PreToolUse hook blocks one of them, the entire batch is cancelled — including any Write/Edit calls that appeared to report success. Cached "File created successfully" replays are not proof the file exists on disk. After any in-batch block, re-read or stat the intended artifacts before relying on them.
