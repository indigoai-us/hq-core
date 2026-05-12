---
id: hq-git-diff-three-dot-for-pr-review
title: Use three-dot diff (A...B) when reviewing a PR, never two-dot
scope: global
trigger: when reviewing a branch's changes vs `main` locally, inspecting a PR diff, or validating "what does this PR actually change"
enforcement: soft
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: session-learning
---

## Rule

ALWAYS use three-dot (`A...B`) when diffing a branch against its base to see the true PR delta:

```bash
git diff main...my-branch           # PR delta — what the branch adds/changes
git diff --stat main...my-branch    # Summary, same semantics
```

NEVER use two-dot (`A..B`) for PR review:

```bash
git diff main..my-branch            # WRONG — symmetric tip-to-tip diff
```

Two-dot `A..B` shows the full symmetric difference between tips — it includes every commit on `main` that your branch is *behind*, represented as deletions. A branch that is behind main by 400 commits but adds only a 1-line change will show ~400 "deletions" under two-dot. Under three-dot it correctly shows `+1 -0`.

Three-dot (`A...B`) diffs against the merge-base of the two refs, which is exactly the view GitHub's PR UI renders and what `mergeable: MERGEABLE · mergeStateStatus: CLEAN` references.

Quick audit when the diff looks suspiciously large (cross-reference `hq-git-large-diff-audit-before-panic` for decomposing a known-large diff):

```bash
# If two-dot and three-dot disagree wildly, you used the wrong form
git diff --stat main..my-branch | tail -1
git diff --stat main...my-branch | tail -1
```

## Rationale

Branches that sit behind `main` for any meaningful period produce dramatically different output under the two diff forms. Two-dot is rarely what a reviewer wants — it conflates "changes on the branch" with "commits on main the branch hasn't caught up to." Three-dot isolates the branch's own contribution, matching:

- GitHub's PR "Files changed" tab
- `gh pr diff`
- The rebase/merge outcome once the branch updates to main

Using two-dot by mistake has triggered multi-person escalations over "hundreds of deletions" that were in fact zero — the branch was simply 300 commits behind. The three-dot form eliminates that failure mode. Use it by default for any PR-scope question, and reserve two-dot for the rare case where symmetric difference is what you actually want (e.g. "what differs between these two refs, regardless of direction of drift?").
