---
id: hq-pull-before-work
title: Always pull latest main before starting repo work
public: true
when: repo
on: [SessionStart]
enforcement: soft
tier: 1
version: 1
created: 2026-03-21
updated: 2026-03-21
source: user-correction
---

## Rule

ALWAYS run `git pull` (or `git fetch && git merge`) on the active branch before making any changes to a repo. If the repo is significantly behind origin (50+ commits), address the divergence before starting new work.

At session start, after identifying the target repo:
1. `cd` to the repo
2. `git fetch origin`
3. Check `git rev-list --count HEAD..origin/main` — if > 0, pull before proceeding
4. If pull fails due to local changes, stash first

