---
id: hq-cmd-publish-kit-rerun-diff-on-scope-narrow
title: Re-Run Diff Analysis When Patch-Release Scope Narrows
scope: command
trigger: /publish-kit patch mode when the user narrows scope mid-plan
enforcement: soft
public: true
version: 1
created: 2026-04-16
updated: 2026-04-16
source: session-learning
---

## Rule

When a patch-release plan is narrowed mid-flow (user excludes files, adds files, or changes the stated scope), the driver MUST re-run the scoped diff (`diff -rq`) on the *new* scope before copying anything. Do not trust the Step-2 diff baseline from the original plan — files that looked byte-identical at plan time may have been touched by a parallel session or earlier step, and files that looked diverged may no longer be relevant.

- Emit the new diff count to the user and confirm before scrub/copy.
- If the new scope is a strict subset, the old diff results are safe to reuse for that subset only — still surface this explicitly ("scope narrowed; reusing 3 of 7 original diffs, skipping the other 4").
- If the new scope includes paths that weren't in the original plan, those paths MUST get a fresh diff pass.

## Rationale

Patch releases are defined by a small, tightly bounded set of changes; a single untracked file-drift into the set causes a noisy PR or, worse, ships unintended content. The diff is cheap (sub-second for `template/`) and eliminates an entire category of "I thought we agreed to X" release surprises. Re-running preserves the invariant that the release branch contains exactly the files the user approved, nothing more.
