---
id: dual-repo-prd-routing
title: Dual-repo PRD routing via story notes
scope: command
trigger: /run-project, /execute-task, /plan
enforcement: soft
---

## Rule

When a PRD spans two repos (`repoPath` + `secondaryRepoPath`), add a `REPO:` prefix in each story's `notes` field directing the sub-agent to the correct repo. Example: `"REPO: This story targets repos/private/{repo-a} (NOT {repo-b}). CD to that repo before working."` Also expand `qualityGates` to run typecheck in both repos using subshell: `"(cd /path/to/secondary/repo && npm run typecheck)"`.

