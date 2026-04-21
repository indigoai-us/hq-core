---
id: hq-run-project-swarm-merge-conflict-tombstone
title: Tombstone swarm runs when a worktree merge conflicts — never silently pass
scope: command
command: run-project
trigger: `/run-project --swarm` merging a worktree branch back into the feature branch
enforcement: hard
version: 1
created: 2026-04-14
updated: 2026-04-14
source: session-learning
---

## Rule

When `scripts/run-project.sh --swarm` merges a per-story worktree branch into the shared feature branch and the merge fails (conflict, hook failure, aborted merge, or any non-zero exit from `git merge`), the orchestrator MUST:

1. **Leave state.json marked `failed` for that story.** Never flip `passes: true` on a story whose merge did not land cleanly.
2. **Tombstone the run summary.** Write `workspace/reports/{project}-summary.md` with `status: FAILED_MERGE` plus the conflicting file list (`git diff --name-only --diff-filter=U`) and the aborted merge SHA (from `.git/MERGE_HEAD`). Do not produce a "success" summary.
3. **Leave `.git/MERGE_HEAD` in place (or capture the SHA) and attach it to the failure report.** The recovery path requires knowing which commit was being merged so the operator can cherry-pick orphans from the reflog.
4. **Surface to the parent session via `progress.txt`:** a `MERGE_CONFLICT story={id} files={...}` line. The polling loop in the `/run-project` skill MUST branch on this and STOP rather than continue.

**Validation contract (script-side):**
```bash
# After merging a worktree branch:
if ! git -C "$repo" merge --no-ff "$worktree_branch" -m "$msg"; then
  conflicted=$(git -C "$repo" diff --name-only --diff-filter=U | tr '\n' ',')
  merge_head=$(cat "$repo/.git/MERGE_HEAD" 2>/dev/null || echo "unknown")
  printf 'MERGE_CONFLICT story=%s files=%s merge_head=%s\n' \
    "$story_id" "$conflicted" "$merge_head" \
    >> "$orchestrator_dir/progress.txt"
  jq --arg sid "$story_id" '.stories[$sid].status = "failed_merge"' \
    "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  exit 2  # hard-stop the swarm run
fi
```

**Validation contract (session-side):** after any `/run-project --swarm` run claims `completed`, the `/run-project` skill MUST verify each claimed story has a non-orphan commit on the feature branch:
```bash
for story_sha in $(jq -r '.stories[] | select(.passes==true) | .commit_sha' state.json); do
  git -C "$repo" branch --contains "$story_sha" | grep -q "$feature_branch" || {
    echo "ORPHAN: $story_sha not on $feature_branch — run is broken"
    exit 2
  }
done
```

