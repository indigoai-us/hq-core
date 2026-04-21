---
id: hq-git-branch-verify
title: Verify Git Branch Before Committing
scope: global
public: true
trigger: before any git commit
enforcement: hard
version: 1
created: 2026-02-22
updated: 2026-02-22
source: migration
---

## Rule

ALWAYS run `git branch --show-current` before committing to any repo. Never assume the current branch — inherited cwd or installs can silently land you on an unintended branch. If wrong branch: create correct branch, cherry-pick, revert from wrong branch.

