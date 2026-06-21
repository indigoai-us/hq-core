---
id: hq-octokit-commit-vs-pr-phases-distinct
title: Octokit git data API — commit phase and PR-open phase are distinct, not atomic end-to-end
scope: global
trigger: any PRD or implementation using Octokit's git data API (createBlob, createTree, createCommit, updateRef) followed by PR creation (e.g. promote-hq-core, or any "commit-and-PR" flow)
when: git && commit
on: [AssistantIntent, PreToolUse]
enforcement: soft
public: true
version: 3
created: 2026-04-22
updated: 2026-04-29
source: session-learning
---

## Rule

Do NOT describe Octokit git data API flows as "atomic" end-to-end. The operation has two distinct phases, and only the first is atomic:

| Phase | Steps | Atomicity |
|-------|-------|-----------|
| **Commit phase** | `createBlob` → `createTree` → `createCommit` → `updateRef` | Atomic — the `updateRef` call either succeeds (commit visible) or fails (commit orphaned and GC'd) |
| **PR-open phase** | `pulls.create` against the committed ref | Separate API call — can fail independently after the commit already landed |

PRDs touching commit-and-PR flows (or any Octokit commit-and-PR pattern) MUST:
1. **Distinguish the two phases** in acceptance criteria — don't lump them into "atomically open PR with N files"
2. **Specify retry behavior** per phase:
   - Commit phase retry → safe (orphan blobs/trees are harmless, `updateRef` is idempotent if the ref already points to the target)
   - PR-open phase retry → check for existing PR on the ref first (avoid duplicate PR creation on retry of a transient network error)
3. **Define the recovery path** when commit succeeds but PR-open fails: the ref exists with the commit, user needs to manually open the PR or the script needs a resume mode that skips the commit phase

## Rationale

Octokit's git data API is commonly described as "atomic" because all file writes aggregate into a single commit via a single `updateRef` call. That framing is correct for the commit phase — either the ref moves or it doesn't. But PR creation is a separate REST call against a different endpoint (`POST /repos/:owner/:repo/pulls`). A 500 / rate-limit / network failure between `updateRef` and `pulls.create` leaves the system with a landed commit and no open PR — a state most "atomic" mental models don't account for.

This matters for promote-hq-core, update-hq, and any flow that does "commit N files and open a PR." If the PRD says "atomically open PR with the scrubbed template tree," it under-specifies the failure mode and retry contract. The actual contract is: "atomically land a commit; then open a PR against that commit (retryable)."

## Anti-patterns

- "Atomic Octokit commit-and-PR" in acceptance criteria → ambiguous on failure mode
- Retrying the commit phase after a PR-open failure → re-commits already-landed content as a second commit on the ref
- No resume mode on commit-and-PR scripts → a transient PR-open failure requires manual recovery
- Logging "PR opened successfully" when only the commit landed → misleads downstream observers
