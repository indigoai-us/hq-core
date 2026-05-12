---
id: publish-kit-diff-and-reconcile
title: Diff against upstream and re-diff on scope-narrow before publishing
scope: command
trigger: "/publish-kit patch or full release, /publish-kit patch mode when user narrows scope mid-plan"
enforcement: soft
created: 2026-04-28
supersedes: hq-cmd-publish-kit-diff-upstream, hq-cmd-publish-kit-rerun-diff-on-scope-narrow
public: true
---

## Rule

publish-kit's release branch must reflect exactly the user-approved scope — no more, no less. Two diff disciplines guard this invariant: diff against actual upstream state before publishing, and re-run the diff whenever the scope narrows mid-flow.

### A. Diff against upstream template state before publishing

ALWAYS diff changed items against the actual upstream template state (`origin/main` + open PR branches) before running `/publish-kit`. Do not rely solely on local commit history to determine what's "unpublished." Features may already exist in open PRs targeting the same repo. Including them again creates merge conflicts and duplicate content.

Concrete check: for each `--item`, verify the file does not already exist (or differ only trivially) on `origin/main` or any open PR branch before copying.

### B. Re-run diff analysis when patch-release scope narrows

When a patch-release plan is narrowed mid-flow (user excludes files, adds files, or changes the stated scope), the driver MUST re-run the scoped diff (`diff -rq`) on the *new* scope before copying anything. Do not trust the Step-2 diff baseline from the original plan — files that looked byte-identical at plan time may have been touched by a parallel session or earlier step, and files that looked diverged may no longer be relevant.

- Emit the new diff count to the user and confirm before scrub/copy.
- If the new scope is a strict subset, the old diff results are safe to reuse for that subset only — still surface this explicitly ("scope narrowed; reusing 3 of 7 original diffs, skipping the other 4").
- If the new scope includes paths that weren't in the original plan, those paths MUST get a fresh diff pass.

## Rationale

**A:** During the v10.7→v10.8 publish session, repo-coordination files (block-on-active-run.sh, check-repo-active-runs.sh, orchestrator.yaml) appeared "unpublished" based on local commit history but were already in open PRs #48/#49. The thorough diff analysis by an Explore agent prevented a duplicate-content PR that would have conflicted with those PRs on merge.

**B:** Patch releases are defined by a small, tightly bounded set of changes; a single untracked file-drift into the set causes a noisy PR or, worse, ships unintended content. The diff is cheap (sub-second for the target tree) and eliminates an entire category of "I thought we agreed to X" release surprises. Re-running preserves the invariant that the release branch contains exactly the files the user approved, nothing more.

The unifying principle: trust the actual tree state, not a stale plan baseline. Both rules are cheap repeat-checks that catch silent reality drift between the plan's "what we'll publish" and the tree's "what's actually different."

