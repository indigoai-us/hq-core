---
id: hq-no-grep-discovery
title: Use Indexes for Project and Worker Discovery
when: grep
on: [PreToolUse]
enforcement: hard
tier: 1
public: true
---

## Rule

Do not use Grep to find `prd.json` or `worker.yaml` files. Use qmd for project discovery, such as `qmd search "project prd.json" --json -n 5`, then read the selected file. Read `core/workers/registry.yaml` to find a worker and read its `worker.yaml`; if the worker is absent, treat it as unavailable and do not fall back to a raw repository script. Read `companies/manifest.yaml` to discover companies. Read a known file directly. Use Grep for exact content searches within a specified directory.

## Rationale

Indexed discovery avoids broad scans and matches the registered legacy hooks.
