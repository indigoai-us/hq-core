---
id: hq-cmd-run-project-ralph-hard-pause-procedure
title: Hard-pause /run-project --ralph-mode via 5-step takedown procedure
scope: global
trigger: Operator decides to hard-pause an in-flight `/run-project --ralph-mode` run before its natural completion
enforcement: hard
public: false
version: 1
created: 2026-04-26
updated: 2026-04-26
source: session-learning
---

## Rule

When hard-pausing `/run-project --ralph-mode`, execute ALL FIVE steps in order. Skipping any step leaves zombie state that blocks the next launch.

1. **CronDelete the monitoring loop.** The detached monitor runs on a cron tick; leaving it alive will respawn UI on a project that no longer has a running orchestrator.
2. **TERM the orchestrator parent, then KILL ~2s later.**
   ```bash
   pkill -TERM -f 'run-project.sh.*<project>'
   sleep 2
   pkill -KILL -f 'run-project.sh.*<project>'
   ```
3. **Explicitly kill orphaned `claude` swarm-worker children.** When the swarm shells exit, their `claude` child PPIDs reparent to init (PID 1). They will NOT die with the parent. Find and kill them:
   ```bash
   pkill -TERM -f 'claude.*<project>' || true
   ```
4. **Patch state.json:** set `status:"paused"` and clear `current_tasks` (otherwise the next launch's pre-flight will refuse to resume).
   ```bash
   jq '.status="paused" | .current_tasks=[]' \
     workspace/orchestrator/<project>/state.json > /tmp/s.json && \
     mv /tmp/s.json workspace/orchestrator/<project>/state.json
   ```
5. **Clear the `workspace/orchestrator/active-runs.json` entry** for the project. Otherwise repo-coordination hooks will block sibling sessions from editing the repo even though no run is active.

### Expected drift after pause

Workers commit ~30s before exiting normally. The TERM→KILL window catches most in-flight commits to worktree branches, but state.json may drift +1 from canonical main: the orchestrator bumps a story's `passes:true` mid-shutdown before `merge_swarm_commits` runs. Plan for one extra reconciliation pass on resume.

## Rationale

A ralph-mode orchestrator is a detached supervisor with three tiers of children: the cron monitor (writes UI), the `run-project.sh` parent (story scheduler), and per-story `claude -p` workers. Each tier holds independent state. A naive `pkill` against the parent leaves the cron and the workers running, and pre-flight will refuse the next launch because `current_tasks` still names a story.

The 5-step procedure addresses each tier in dependency order: cron first (so it stops dispatching), parent second (so no new workers spawn), workers third (re-parented orphans never get a SIGTERM cascade), state.json fourth (resume becomes legal), active-runs.json fifth (sibling sessions regain edit rights).

## Provenance

Captured during a curriculum-expansion hard-pause (~18 of 32 stories complete). First attempt skipped step 3; orphaned `claude` workers continued committing to worktree branches for ~5 minutes after the parent died.

## Related

- `.claude/policies/repo-run-coordination.md` — active-runs.json semantics
- `.claude/policies/hq-cmd-run-project-paused-preflight-resume-md.md` — companion resume artifact
- `.claude/policies/hq-bash-discipline.md` — pgrep hygiene (rule 6) for step 2
