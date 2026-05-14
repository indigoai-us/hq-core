---
name: finish-estimate
description: Mark a pending time estimate complete with an actual duration.
allowed-tools: Bash, Read
---

# Finish Estimate

Codex adapter for `/finish-estimate`.

**Arguments:** `<estimate-id|latest> <actual-duration> [notes]`

## Source Of Truth

Read `.claude/commands/finish-estimate.md` first. That command owns the estimate lookup, duration normalization, ratio calculation, JSONL rewrite, and report format.

## Codex Adaptation

- Execute the command workflow inline from the HQ root.
- Use `workspace/estimate-log/log.jsonl` as the log source.
- Prefer `jq` or a structured JSON parser for line rewrites.
- Rewrite the log atomically through a temp file and preserve one JSON object per line.
- If the target estimate cannot be found, stop without modifying the log.

## Completion

End with the estimate id, task, expected minutes, actual minutes, ratio, verdict, and notes when supplied.
