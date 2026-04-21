---
id: hq-cmd-run-project-pid-tracking
title: Orchestrator PID tracking mismatch — use prd.json passes as source of truth
scope: command
trigger: run-project, monitoring
enforcement: soft
version: 1
created: 2026-03-29
updated: 2026-03-29
source: success-pattern
---

## Rule

When monitoring `run-project.sh` execution, NEVER rely solely on PID liveness from check-in status. The orchestrator tracks the shell wrapper PID (`bash -c "claude -p ..."`), not the actual `claude -p` process PID. This causes check-ins to show "exited" while the real subprocess is still actively working.

ALWAYS verify story completion via:
1. `jq '.userStories[] | select(.id == "US-XXX") | .passes' prd.json` — the definitive source of truth
2. `git log --oneline` — new commits indicate active work
3. `ps aux | grep "claude.*{story-id}"` — find the real process PID

When the orchestrator shows a story PID as "exited" but `passes` is still false: check for the real `claude -p` process before declaring failure.

