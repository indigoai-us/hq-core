---
id: reread-before-edit-long-sessions
title: Re-Read Files Before Edit in Long Sessions
scope: global
trigger: before editing files after 10+ conversation turns or after compaction
when: always
on: [SessionStart]
enforcement: soft
version: 1
created: 2026-03-31
source: brainstorm-session
public: true
---

## Rule

After 10+ conversation turns, or if context compaction has occurred, re-read any file before editing it. Do not trust cached/remembered file contents — compaction may have silently discarded the original read.

Also: after editing a file, read it back to confirm the edit applied correctly. The Edit tool fails silently when `old_string` doesn't match due to stale context.

Do not batch more than 3 edits to the same file without a verification read.

## Rationale

Auto-compaction keeps a compressed summary but discards original file reads. Editing against stale state causes silent Edit tool failures (old_string not found) or worse — edits applied to wrong locations. Re-reading is cheap; fixing a corrupted file is expensive.
