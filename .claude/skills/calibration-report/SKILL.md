---
name: calibration-report
description: Summarize assistant time-estimate accuracy by category from the estimate log.
allowed-tools: Bash, Read
---

# Calibration Report

Codex adapter for `/calibration-report`.

**Arguments:** `[--category X] [--since YYYY-MM-DD] [--abandon-stale] [--show-misses]`

## Source Of Truth

Read `.claude/commands/calibration-report.md` first. That command owns the log path, filters, stale-abandon behavior, statistics, and report format.

## Codex Adaptation

- Execute the command workflow inline from the HQ root.
- Prefer `jq` and existing parser helpers over ad hoc string parsing.
- If the estimate log does not exist or is empty, report that directly and make no files.
- Only mutate `workspace/estimate-log/log.jsonl` when `--abandon-stale` is present.
- Keep the report compact: totals, per-category calibration table, pending/stale count, and optional worst misses.

## Completion

End with the calibration summary and any suggested multiplier changes. Mention whether the log was modified.
