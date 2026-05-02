---
id: hq-cmd-handoff-no-discovery-rerun
title: Never re-run handoff-finalize.sh just to discover the thread path
scope: command
trigger: "/handoff or any caller of scripts/handoff-finalize.sh that needs the thread file path"
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

**NEVER** invoke `scripts/handoff-finalize.sh` a second time (synchronously or in a backgrounded subshell) for the sole purpose of "discovering" the thread file path or handoff.json state. Every invocation of `handoff-finalize.sh`:

1. Writes a **new** thread file (derived from the arguments passed, which in a rerun are almost always empty/placeholder values).
2. **Overwrites** `workspace/threads/handoff.json` with the new run's fields.

A "discovery" rerun with empty fields therefore destroys the good handoff produced by the primary run — the committed handoff.json now points at a near-empty thread file with no summary, blockers, or next-step context.

**Correct pattern — parse, don't rerun:**

The primary `handoff-finalize.sh` run prints a trailing JSON line to stdout of the form:

```json
{"thread":"workspace/threads/T-YYYYMMDD-HHMMSS-slug.json","handoff":"workspace/threads/handoff.json","commit":"<sha>"}
```

When a downstream step (e.g. `scripts/handoff-bg-commit.sh`, a detached `/learn` run, or `handoff-post.sh`) needs the thread path, it must **parse that JSON from the captured stdout**, not rerun the script. Examples:

```bash
# Capture once
FINALIZE_OUT=$(bash scripts/handoff-finalize.sh --summary "..." --next-steps "...")
THREAD_PATH=$(echo "$FINALIZE_OUT" | tail -1 | jq -r .thread)

# Pass THREAD_PATH into the background job
nohup bash scripts/handoff-post.sh "$THREAD_PATH" &
```

If the thread path is needed in a separate shell (no captured stdout), read `workspace/threads/handoff.json` directly — it is the durable pointer — and extract `thread_file` via `jq`. Still zero reruns.

**If you catch yourself about to write `bash scripts/handoff-finalize.sh ... &` a second time in the same handoff chain, stop.** Parse instead.

## Rationale

During the 2026-04-21 onboarding domain deprecation handoff, a background-commit script was chained to a second `handoff-finalize.sh` invocation whose arguments were empty because the intent was "just tell me the thread path." The rerun successfully wrote a new (near-empty) thread file AND overwrote handoff.json with empty summary/blockers/next-steps, silently discarding the real handoff the primary call had just committed. Recovery required grepping the git log for the last good JSON and manually restoring handoff.json.

Root cause: treating a side-effecting generator as a read-only query. The script's contract is "produce a handoff," not "tell me about one." The durable record is the JSON line on stdout and the committed `workspace/threads/handoff.json` — both are available without re-execution.

This class of bug (re-invoking a side-effecting CLI as a probe) recurs anywhere a tool's stdout happens to contain useful identifiers. The fix is always the same: capture stdout once, parse downstream.
