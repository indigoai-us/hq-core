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

Create options also require a title: append `--create-project '<approved project title>'`
or `--create-task '<approved task title>'` to organize. Reuse an already approved
title, or obtain it before submitting. Existing choices need neither flag.

## Project registration after planning

Local `board.json` is not the server `PROJECT_VIEW`. Before registration, persist
and verify the canonical server view through the supported authenticated HQ
client, using the approved company API and exact project ID. Never print or paste
tokens. Complete these steps in order:

1. **Read before writing:** authenticated
   `GET /v1/work-mesh/projects/{projectId}?companyUid={companyUid}`.
   Verify the returned `companyUid` and `projectId` exactly match the approved
   plan. Only a confirmed 404 means the view is absent; stop on authorization,
   transport, or other errors. If the existing view already matches the required
   stories and repos, reuse it without a PUT.
2. **Persist the server view:** authenticated
   `PUT /v1/work-mesh/projects/{projectId}` with `companyUid`, name, description,
   complete `stories`, and complete `repos` in the JSON body. Map `userStories`
   to story IDs and content; map all `metadata.repos` entries to supported repo
   records. Do not send the local board entry or an empty/stub view as the plan.
   For an existing view, merge by story ID and repo identity, preserve live story
   statuses and other server activity fields, and retain unrelated server entries.
   Never replace live statuses with local `passes: false` or default queued values.
   The current public PUT is a full replacement and has no conditional-version
   guard: do not assume sending `expectedVersion` protects it. Coordinate exclusive
   writing before changing an existing view; if that cannot be established, stop
   and report the required merge instead of risking concurrent status updates.
3. **Verify persistence:** repeat the authenticated
   `GET /v1/work-mesh/projects/{projectId}?companyUid={companyUid}` after PUT (or
   inspect the successful GET when reusing an unchanged view). Verify the exact
   company and project IDs, every planned story ID and its content, and every
   planned repo identity/path. Compare full ID sets and mappings, not just counts;
   confirm previously live story statuses and retained entries are unchanged.
   On any missing entry or mismatch, report the view as incomplete and stop.
4. **Register only after verification:** authenticated
   `POST /v1/work-mesh/projects/{projectId}/register` with JSON body
   `{"companyUid":"<resolved company UID>"}`. Reuse the same canonical project ID.

This operation requires the existing tenant-scoped project view, creates or
reuses its deterministic genesis, and ensures its project channel. Require a
successful response containing both `threadId` and `channelId` before reporting
registration complete. Confirm the channel is readable with the current identity.
A Board view, cached thread ID, session presence, or successful note alone is not
proof of registration or channel creation.

If registration fails or the deployed server does not support this operation,
report registration/channel creation as incomplete and preserve the plan and
canonical ID. Inspect partial state before recovery; never create a replacement
project or weaken tenant ownership checks. Presence hooks remain automatic and
do not perform this project-registration step.

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
