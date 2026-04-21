---
id: prd-json-schema
title: "prd.json uses userStories, qualityGates, baseBranch"
scope: command
trigger: "/prd, prd.json creation"
enforcement: hard
created: 2026-03-24
---

## Rule

When creating `prd.json` files:
- Story array key MUST be `userStories` (not `stories`)
- Dependency key MUST be `dependsOn` (not `depends`)
- Repo path MUST be `metadata.repoPath` (not top-level `repo`)
- Each story MUST have `"passes": false` initialized
- Each story MUST have `"priority": N` (integer, lower = higher priority)
- `metadata` MUST include `qualityGates` array (e.g. `["bun run test", "bun run build", "bun run lint"]`)
- `metadata` MUST include `baseBranch` string (e.g. `"main"`)

