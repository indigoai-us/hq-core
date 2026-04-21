---
id: hq-run-project-swarm-branch-validation
title: Validate story commits land on feature branch after swarm-mode merges
scope: command
command: run-project
trigger: `/run-project --swarm` declaring a story complete
enforcement: hard
version: 1
created: 2026-04-15
updated: 2026-04-15
source: session-learning
---

## Rule

Before `run-project.sh` marks a story `completed` in swarm mode, the orchestrator MUST verify the story's merge commit lives on `{prd.branchName}` and NOT on `main`. If the merge commit's branch resolution returned `main`, the story is NOT complete — abort the story and surface the error.

**Validation contract (script-side):**
```bash
# After merging a worktree's branch into the shared feature branch:
merge_sha=$(git -C "$repo" rev-parse HEAD)
feature_branches=$(git -C "$repo" branch --contains "$merge_sha" --format='%(refname:short)' | grep -v '^main$')
if [ -z "$feature_branches" ]; then
  echo "ABORT: story $story_id merge landed only on main, not on $feature_branch"
  exit 2
fi
```

**Validation contract (session-side):** after any `/run-project --swarm` run, diff `main..{feature-branch}` in the affected repo and confirm the number of commits matches the number of completed stories. If main moved while the feature branch did not, the orchestrator is broken — STOP and recover before the user merges main forward.

