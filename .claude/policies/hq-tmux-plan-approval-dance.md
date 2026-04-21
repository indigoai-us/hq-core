---
id: hq-tmux-plan-approval-dance
title: Tmux orchestrator sessions require multiple manual approvals
scope: command
trigger: /run-project --tmux, tmux session monitoring
enforcement: soft
version: 1
created: 2026-03-26
updated: 2026-03-26
source: success-pattern
---

## Rule

When `/run-project --tmux` launches a Claude session in tmux, the session requires 3 sequential approvals before execution begins:

1. **Plan approval** — Claude enters plan mode, explores the PRD, writes a plan. Select option 1 ("Yes, clear context and auto-accept edits").
2. **Bash command approval** — Claude runs a Python/bash exploration command that contains newlines. Approve.
3. **Background launch approval** — Claude launches `nohup bash scripts/run-project.sh` with newline separators. Approve.

Each approval requires `tmux send-keys -t {session} Enter`. Wait ~30-90 seconds between each for Claude to process.

After all 3 approvals, the background `run-project.sh` process starts and the tmux Claude enters a polling loop monitoring state.json. No further approvals needed until the next resume.

