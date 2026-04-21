---
id: orchestrator-competing-processes
title: Kill stale orchestrator PIDs before resuming
scope: command
trigger: /run-project --resume
enforcement: soft
---

## Rule

Before running `--resume` on a project, check for existing `run-project.sh` processes for that project (`ps aux | grep "run-project.*{project}"`). Kill all stale PIDs before launching a new one. Competing processes truncate shared state files (state.json, progress.txt, run.log) to 0 bytes. PRD `passes` field and git commits are the ground truth for recovery.

