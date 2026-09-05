---
name: work-mesh
description: Work Mesh Live — automatic presence via hq mesh daemon; context reconcile/organize; manual session task-status, blocked, and note only.
allowed-tools: Bash, Read
---

# Work mesh

Presence and per-turn activity are **automatic**. Do not call deleted
`core/scripts/work-mesh.sh` / pack `listen` / `watch`. Use **hq-cli**:

## Daemon

```bash
hq mesh daemon install
hq mesh daemon status
hq mesh daemon doctor
```

One resident process per machine. Flushes `~/.hq/work-mesh/spool.jsonl`, holds
unverified-company events, publishes MQTT presence (LaunchAgent
`ai.getindigo.hq-mesh-daemon` / systemd `hq-mesh-daemon.service`).

## Context

```bash
hq mesh context reconcile --observation-file <path> --machine
# or: hq mesh context reconcile --observation-json '<json>' [--machine] [--offline]
hq mesh context default get|set|clear
hq mesh context untracked <sessionId>
hq mesh context organize --session <sid> --decision <id> --option <id>
hq mesh context correct --session <sid> --to-company <slug> [--project <id>] [--task <id>]
```

`reconcile` takes observation input only (no `--session`). `organize` / `correct` / `untracked` keep `--session` (or the sessionId argument).

## Session (manual only)

```bash
hq mesh session task-status --session-id <sid> --enqueue --seq <n> --task-id <id> --status queued|in_progress|review|done
hq mesh session blocked --session-id <sid> --enqueue --seq <n> --reason "<short>"
hq mesh session note --session-id <sid> --enqueue --seq <n> --summary "<<=280 chars>"
hq mesh session flush
```

Session verbs use `--session-id` (not `--session`).
Hooks already enqueue `session_start` / `turn_start` / `turn_end` / `session_end`.
Policy: `core/policies/hq-project-work-mesh-reporting.md`.
