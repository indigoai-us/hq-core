---
id: hq-orchestrator-lockfile-sync
title: Run npm install in orchestrator completion flow
scope: command
trigger: run-project completion flow, after all stories pass
enforcement: hard
version: 1
created: 2026-03-19
updated: 2026-03-19
source: back-pressure-failure
---

## Rule

After all stories complete in run-project.sh, run `npm install` (or equivalent package manager install) in the project repo and commit the updated lockfile before the completion flow finishes. Sub-agents add dependencies to package.json during story execution but don't always regenerate the lockfile. Vercel and CI do clean installs from the lockfile — stale lockfiles cause "Module not found" build failures.

