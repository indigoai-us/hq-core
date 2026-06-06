---
id: hq-pr-single-concern
title: One PR, One Concern — Never Bundle Unrelated Changes
scope: global
trigger: before creating any pull request, before committing changes that span multiple features
when: git && commit
on: [PreToolUse]
enforcement: hard
tier: 1
version: 1
created: 2026-04-02
updated: 2026-04-02
source: session-learning
public: true
---

## Rule

1. **Every PR must address exactly one concern.** A concern is: one bug fix, one feature, one refactor, one infrastructure change, or one dependency update. If you cannot describe the PR in a single sentence without "and," it likely contains multiple concerns.
2. **Before creating a PR, review the diff for unrelated changes.** If the diff includes changes to files or systems unrelated to the stated goal, split them into separate PRs.
3. **Work-in-progress code for a different feature must not ride along in another PR.** If a branch contains partial work on feature B while primarily implementing feature A, revert or stash the feature B changes before opening the PR.
4. **Infrastructure changes (configs, dependencies, CI, migrations) must ship separately from feature code** unless the feature strictly requires the infrastructure change to function. If they can be deployed independently, they must be PRed independently.
5. **If you realize mid-PR that the scope has expanded, stop and split.** Create a stacked PR or separate branches rather than continuing to add to a growing PR.

## Rationale

PR #2980 merged unready messaging infrastructure commits alongside a Shopify identity fix. The messaging changes were incomplete and took down the messaging app in production, requiring an 11-minute emergency revert. Had the identity fix been in its own PR, it could have shipped safely while the messaging work continued on its branch. Mixed PRs make rollback impossible without also reverting the good changes.
