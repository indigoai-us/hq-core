---
id: hq-qmd-first-for-hq-search
title: Use qmd First for HQ Search
scope: global
trigger: when searching HQ content, indexed repos, projects, workers, policies, or knowledge
enforcement: hard
tier: 1
version: 1
created: 2026-05-14
updated: 2026-05-14
source: user-correction
public: true
---

## Rule

ALWAYS use `qmd` first for HQ search across content, indexed repos, projects, workers, policies, and knowledge. Use `qmd search` for keyword search, `qmd vsearch` for conceptual search, and `qmd query` when hybrid ranking is needed. Fall back to Grep, shell search, or direct file listing only when `qmd` is unavailable, errors, or the task is exact pattern matching in already-scoped code.

## Rationale

HQ is indexed with qmd so searches stay scoped, fast, and aligned with the workspace's semantic collections. Broad Grep or shell search from HQ root is noisy, can traverse irrelevant generated data, and misses the intended collection model.
