---
name: handoff-all
description: "Tell every open Claude Code desktop session to run /handoff, then collect each session's /resumework command. Triggers: \"handoff all sessions\", \"wrap up every session\"."
allowed-tools: Bash, Read, AskUserQuestion, mcp__ccd_session_mgmt__list_sessions, mcp__ccd_session_mgmt__get_session, mcp__ccd_session_mgmt__send_message, mcp__ccd_session_mgmt__list_events
---

# Handoff All Sessions

Broadcast `/handoff` to every open desktop session and return one HQ resume
command (`/resumework <thread-id>`) per session. Never return Claude-native
resume commands (`claude --resume`, session links) as the resume path.

**Arguments:** `$ARGUMENTS` — optional `--dry-run` (stop after step 2),
`--running-only` (skip idle sessions), `--include <id,...>`, `--exclude <id,...>`.

## Requirements

- Desktop app runtime with the `ccd_session_mgmt` tools. In the terminal CLI
  or headless (`CLAUDE_HEADLESS=1`), STOP and say this skill needs the desktop app.

## Process

### 1. Inventory

Call `list_sessions` with `limit: 100`, `include_archived: false`. The current
session is excluded automatically. Apply `--running-only`, `--include`,
`--exclude`. Skip unattended sessions (scheduled-task runs); `send_message`
cannot deliver to them.

### 2. Readiness table and confirm

Show a table: title, running/idle, last activity, session id. Sending a
message starts a turn in each target session, so this is an outward action.
Ask for an explicit go with `AskUserQuestion` (options: send to all listed /
running only / cancel). `--dry-run` stops here.

### 3. Broadcast

For each target, call `send_message` with this body (verbatim, fill nothing):

> Run `/handoff` now to close out this session. In the handoff, record every
> active /conduct lane, background agent, PR watch, and other tracked item with
> its id, state, and next step, plus whether this session was in conduct mode
> (engine and child model). When it finishes, reply with
> exactly one final line in the form `HQ-RESUME: /resumework <thread-id>`. If
> this session produced no resumable state, reply `HQ-RESUME: none (<reason>)`.

Record the returned delivery status (`delivered` / `queued` / error) and
`message_id` per session. Do not retry errors blindly; report them.

### 4. Collect

Poll each session with `list_events` (back off, roughly every 60s, cap ~20
minutes) for the `HQ-RESUME:` line. As a fallback, match new thread files:
`ls -t workspace/threads/T-*.json | grep -v changeset` created after the
broadcast, using each thread's session/title fields to map it to a session.

### 5. Write the batch manifest

Write `workspace/handoff-all/<batch-id>.json` where `<batch-id>` is
`HA-YYYYMMDD-HHMMSS`. This file is the only input `/resume-all` trusts.

```json
{
  "batch_id": "HA-20261003-031500",
  "created_at": "<ISO-8601>",
  "resumed_at": null,
  "sessions": [
    {"session_id": "local_...", "title": "...", "cwd": "...",
     "status": "handed_off|no_state|failed|no_reply",
     "thread_id": "T-...", "resume_command": "/resumework T-...",
     "conduct": {"enabled": true, "engine": "claude", "child_model": "..."}}
  ]
}
```

### 6. Report

Final message lists one row per session:

| Session | Status | Resume command |
|---|---|---|
| title | handed off / no state / failed / still running | `/resumework T-...` |

Flag sessions that never answered or errored. Do not run `/handoff` for this
session unless the user asks.
