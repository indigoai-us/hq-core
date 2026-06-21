---
id: hq-verify-git-after-compact
title: Verify git state after a compact boundary before redoing committed work
scope: global
trigger: resuming a session from an auto-compact summary that mentions pending commits
when: git && commit
on: [AssistantIntent, PreToolUse]
enforcement: soft
public: true
version: 3
created: 2026-04-17
updated: 2026-04-29
source: session-learning
---

## Rule

ALWAYS: When a session spans a compact boundary, verify any "pending commit" claim in the post-compact summary against the actual git state before redoing work. Run `git log --oneline -- <path>` and `git status <path>` on the files the summary flagged. Only treat them as uncommitted if git agrees. The compact summary is a narrative snapshot and drifts from the repo's real state — trusting it blindly leads to duplicated commits or unnecessary re-edits.

ALWAYS: After a context-compaction boundary, run `git status` in every repo you edited before assuming state is preserved. Some Edit results are summarized as succeeded but the underlying file delta can be dropped silently during compaction. If `git status` (or `git diff <path>`) shows no change where the compact summary claims a successful edit, re-apply the edit from the plan or prior transcript — do not assume the summary is authoritative.

## Rationale

During an applies_to backfill session, the post-compact summary asserted 38 tagged policies + scripts + hooks were pending commit. `git log --oneline -- core/scripts/backfill-policy-applies-to.sh` revealed the work had already landed in an earlier checkpoint commit (`e4eac4507`). Re-committing would have been a no-op at best; at worst it could have reintroduced stale state.

The inverse failure mode is equally common: a compact summary reports an Edit/Write as complete, but the compaction process drops the tool-call delta before it's persisted. The file on disk is unchanged, yet the session "remembers" the edit landing. Only `git status` / `git diff` can confirm — the summary is a language-model reconstruction, not a git log. Cross-check in BOTH directions: claimed-pending commits may already be landed, and claimed-completed edits may be missing from the tree.
