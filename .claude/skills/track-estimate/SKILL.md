---
name: track-estimate
description: Manually log a time estimate when automatic estimate capture misses it.
allowed-tools: Bash, Read
---

# Track Estimate

Codex adapter for `/track-estimate`.

**Arguments:** `<task description> <duration>`

## Source Of Truth

Read `.claude/commands/track-estimate.md` first. That command owns the duration parser, category classifier, id format, log path, and output format.

## Codex Adaptation

- Execute the command workflow inline from the HQ root.
- Ask for missing task or duration if the argument cannot be parsed safely.
- Prefer the existing estimate parser helper when available; otherwise mirror its documented duration normalization exactly.
- Append one canonical JSON object to `workspace/estimate-log/log.jsonl`.
- Keep the estimate pending until `/finish-estimate` records the actual duration.

## Completion

End with the tracked task, estimate id, normalized expected minutes and range, category, and the exact `/finish-estimate` command to close it later.
