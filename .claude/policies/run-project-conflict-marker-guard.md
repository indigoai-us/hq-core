---
id: run-project-conflict-marker-guard
title: Orchestrator auto-commit must refuse conflict markers
scope: command
trigger: validate_git_state, orchestrator auto-commit, [orchestrator] commit message
enforcement: hard
version: 1
created: 2026-04-16
updated: 2026-04-16
source: back-pressure-failure
command: run-project
---

## Rule

`validate_git_state()` in `scripts/run-project.sh` (and every swarm-merge auto-commit path) MUST scan the staged diff for unresolved merge-conflict markers before calling `git commit`. If any staged file contains a line matching `^(<{7}|={7}|>{7})([^<=>]|$)`, the orchestrator MUST:

1. Log the offending file paths at error level
2. `git reset` the index to drop the bad stage
3. Return a non-zero status so the outer loop treats the story as failed and pauses

The orchestrator MUST NOT fall back to `git add -A && git commit --no-verify` as an unconditional sweep. Pre-existing un-ignored garbage in the worktree (half-resolved merges, leftover dry-run artifacts, stashed conflicts) is not the sub-agent's output and must never ride into the branch under a `[orchestrator] ...: auto-commit uncommitted work` message.

## Required code shape

```bash
# After: git -C "$REPO_PATH" add -A
local _marker_files
_marker_files=$(git -C "$REPO_PATH" diff --cached --name-only 2>/dev/null | while IFS= read -r _f; do
  [[ -f "$REPO_PATH/$_f" ]] && grep -lE '^(<{7}|={7}|>{7})([^<=>]|$)' "$REPO_PATH/$_f" 2>/dev/null
done)
if [[ -n "$_marker_files" ]]; then
  log_err "REFUSING auto-commit for ${story_id}: conflict markers detected in:"
  while IFS= read -r _f; do [[ -n "$_f" ]] && log_err "  $_f"; done <<< "$_marker_files"
  log_err "  Resetting index — manual cleanup required before run can continue."
  git -C "$REPO_PATH" reset -q 2>/dev/null || true
  return 1
fi
# Only now: git commit ...
```

The regex's trailing `([^<=>]|$)` disambiguates real 7-char Git markers (`<<<<<<< HEAD`) from longer banner/divider strings (`<<<<<<<<` in ASCII art) to avoid false positives in markdown/comments.

## Propagation

- `scripts/run-project.sh` (main HQ)
- `repos/public/hq/template/scripts/run-project.sh`
- `repos/public/hq/template/.claude/scripts/run-project.sh`
- `repos/public/hq-starter-kit/.claude/scripts/run-project.sh`
- Audit swarm-merge commit sites (currently lines ~3281-3298 in `run-project.sh`) and apply the same guard before their `git commit` calls.

## Operational note

When this guard trips during a live run, the orchestrator pauses. Recovery is: inspect the flagged files, `git checkout <ref> -- <files>` to restore or manually resolve the conflicts, then resume. Never force-commit past the guard.
