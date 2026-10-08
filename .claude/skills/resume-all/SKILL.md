---
name: resume-all
description: "Relaunch every session from a /handoff-all batch as a new Claude Code desktop session running its /resumework command. Triggers: \"resume all sessions\", \"bring back the handed-off sessions\"."
allowed-tools: Bash, Read, AskUserQuestion, mcp__ccd_session_mgmt__start_session, mcp__ccd_session_mgmt__list_sessions, mcp__ccd_session_mgmt__get_session
---

# Resume All Sessions

Start one new desktop session per thread recorded by a `/handoff-all` batch.
Each new session runs that thread's `/resumework <thread-id>`. Only batch
manifests written by `/handoff-all` count. Ordinary `/handoff` threads are
never picked up here, even if they are newer.

**Arguments:** `$ARGUMENTS` — optional `<batch-id>` (default: latest batch),
`--dry-run`, `--include <thread-id,...>`, `--exclude <thread-id,...>`, `--force`
(allow a batch that was already resumed).

## Requirements

- Desktop app runtime with the `start_session` session-management tool. In the
  terminal CLI or headless (`CLAUDE_HEADLESS=1`), STOP and print the
  `/resumework` commands so the user can paste them by hand.

## Process

### 1. Load the batch

```bash
dir=workspace/handoff-all
batch="${BATCH_ID:-$(ls -t "$dir"/HA-*.json 2>/dev/null | head -1)}"
```

- No manifest: STOP. Tell the user to run `/handoff-all` first.
- `resumed_at` already set and no `--force`: STOP and say when it was resumed.

### 2. Select targets

Keep entries with `status: handed_off` and a `thread_id`. Apply include/exclude.
For each, confirm the thread file still exists under `workspace/threads/` (or
`workspace/threads/archive/**`). Drop missing ones and report them. Skip any
thread already held by a live resume lock (`core/scripts/resume-thread-lock.sh`)
so two sessions do not resume the same thread.

### 3. Confirm

Show a table: original title, thread id, working folder. Starting sessions
spends usage and each one begins work immediately, so ask for an explicit go
with `AskUserQuestion` (start all / pick a subset / cancel). `--dry-run` stops here.

### 4. Launch

For each target, call `start_session` with:

- `cwd`: the entry's `cwd` (fall back to the HQ root)
- `title`: the original title, unchanged
- `prompt`: `/resumework <thread-id>`. When the entry's `conduct.enabled` is
  true, append: "Then re-enter /conduct with engine <engine> and child model
  <child_model>, and reactivate every lane and tracked item listed in the
  handoff. Report any item that cannot be restored."

Launch sequentially. Record the new session id or the error per entry. Do not
retry a failed launch automatically.

### 5. Record and report

Set `resumed_at` and add `resumed_session_id` per entry in the manifest. Final
message: one row per thread with the original title, the new session link
(`[title](#<sessionId>)`), and status (started / skipped / failed with reason).
