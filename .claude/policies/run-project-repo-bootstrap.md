---
id: hq-run-project-repo-bootstrap
title: Bootstrap repo before run-project.sh launch
scope: command
trigger: /run-project with new repo that doesn't exist yet
enforcement: hard
version: 1
created: 2026-03-28
updated: 2026-03-28
source: success-pattern
---

## Rule

Before launching `run-project.sh`, verify the PRD's `metadata.repoPath` exists as a git repo with at least one commit. The script uses git worktrees for branch isolation, which fail on non-existent or empty repos.

Pre-flight bootstrap:
```bash
mkdir -p {repoPath} && cd {repoPath} && git init && git commit --allow-empty -m "init"
```

Also update `companies/manifest.yaml` to register the new repo under the correct company.

