---
id: hq-installer-tauri-capabilities-artifact-isolation
title: Never sweep auto-generated Tauri capabilities.json into unrelated feature PRs
scope: repo
trigger: staging changes in the hq-installer repo (or any Tauri repo) when src-tauri/gen/ has churned
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

NEVER: Include auto-generated Tauri manifest artifacts — most notably `src-tauri/gen/schemas/capabilities.json` — in a feature PR whose logical scope is unrelated to the capabilities list. These files are regenerated whenever the Tauri tooling refreshes any capability manifest, so they routinely appear as dirty during unrelated UI or behavior work.

Before committing:

```bash
git status --short src-tauri/gen/ | head -20
```

If `capabilities.json` (or any file under `src-tauri/gen/schemas/`) has churned but you did NOT intentionally edit the capability set in this branch, EITHER:

1. `git checkout -- src-tauri/gen/schemas/capabilities.json` to discard the regen noise, OR
2. Move those hunks into the PR that actually changed capabilities (permissions, plugin set, etc.) and commit them there — never sweep them into a UI PR.

## Rationale

`src-tauri/gen/schemas/capabilities.json` is produced by Tauri's build tooling and reflects the current superset of declared capabilities. Because it regenerates on any capability-graph change, it almost always shows up dirty in the working tree even on branches that never touched permissions. If a feature PR sweeps it in, the diff implies an intentional capability change, which (a) misleads reviewers, (b) couples unrelated changes — making the next capability-scoped PR look like a revert — and (c) can clobber intentional capability edits that landed in parallel. Keep regen artifacts with the logical change that motivated them. Captured 2026-04-21 during hq-installer PR review.
