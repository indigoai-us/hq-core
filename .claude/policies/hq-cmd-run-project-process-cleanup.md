---
id: hq-cmd-run-project-process-cleanup
title: Kill stale orchestrator processes before launching new ones
scope: command
trigger: run-project, resume
enforcement: soft
version: 1
created: 2026-03-10
updated: 2026-03-10
source: success-pattern
---

## Rule

Before launching `run-project.sh` (especially with `--resume`), always check for existing orchestrator and sub-agent processes:

```bash
ps aux | grep -E "run-project.*{project}|claude.*execute-task.*{project}" | grep -v grep
```

If stale processes exist, kill them before launching. Multiple orchestrator instances pile up and create orphaned `claude -p` sub-agents that:
- Waste compute (orphaned sub-agents run indefinitely at 0% useful output)
- Corrupt `state.json` (race conditions on `current_task`, duplicate `completed_tasks` entries)
- Spawn new sub-agents from dying parents (kill → child spawns → need to kill again)

