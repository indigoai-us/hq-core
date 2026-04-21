---
id: hq-cmd-handoff-must-complete
title: /handoff must complete every step — verify handoff.json pointer was actually written
scope: command
trigger: when the /handoff skill runs, specifically at and after Step 7 (writing workspace/threads/handoff.json)
enforcement: hard
public: true
version: 2
created: 2026-04-16
updated: 2026-04-16
source: user-correction
---

## Rule

When the user requests `/handoff`, the skill MUST complete every step without fail. Never report handoff as done while any step is incomplete.

**Never pause mid-handoff to ask the user for permission, status confirmation, or direction.** Once `/handoff` starts, drive the skill through every step autonomously — even after context compaction or tool-permission errors. Retry failed tool calls; resume the skill at the correct step after a compaction break; surface problems in the final Step 8 report, not as blocking mid-flight questions. The only mid-flight pauses allowed are the interactive questions the skill explicitly prescribes (e.g. Step 0b's knowledge-update picker, if applicable). A status check from the user ("status?") does not imply permission was required — keep going unless the user explicitly says stop.

Specifically at Step 7 (write `workspace/threads/handoff.json`):

1. After the Write tool returns success, Read `workspace/threads/handoff.json` back and confirm `last_thread` matches the current session's `thread_id`.
2. If the Write failed with "File has been modified since read" or any other error, retry: Read the file again, then Write with the new content. Repeat until the write succeeds and verification passes.
3. Do NOT rely on "the git commit looked successful" as proof — `git add -A && git commit` may capture adjacent changes (recent.md, thread file) while `handoff.json` silently stayed stale. The commit message and diff stats can look identical whether or not `handoff.json` was actually updated.
4. Only after verification passes may the skill proceed to Step 8 and report "Handoff ready."

If any step (commit, INDEX update, qmd reindex launch, handoff.json write) cannot complete, surface the failure to the user in the Step 8 report — do not hide it.

