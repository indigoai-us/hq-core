---
id: hq-gitignore-before-first-commit
title: Create .gitignore before first commit in new projects
scope: global
public: true
trigger: scaffolding a new project with git init
enforcement: hard
version: 1
created: 2026-02-23
updated: 2026-02-23
source: back-pressure-failure
---

## Rule

ALWAYS create `.gitignore` (with `node_modules/`, `.next/`, `.vercel/`, build artifacts) BEFORE running `git init && git add -A && git commit`. If build artifacts enter git history, GitHub rejects pushes for large files and the only fix is nuking `.git` and reinitializing.

