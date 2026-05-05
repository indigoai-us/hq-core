---
name: quality-gate
description: Universal pre-commit quality checks (typecheck, lint, test, coverage, dead code) with auto-detection and --fix support
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# Quality Gate

Codex adapter for `/quality-gate`.

**Arguments:** [--fix] [--coverage-min=80] [--deadcode]

## Source Of Truth

Read `.claude/commands/quality-gate.md` first. That slash command owns the workflow, flags, safety gates, file locations, and completion criteria. This skill exists so Codex can discover and execute the same HQ capability without duplicating the full command body.

## Codex Adaptation

Execute the command workflow inline from the HQ root with the user's requested arguments.

- Preserve the command's default mode, dry-run behavior, and confirmation gates.
- Treat Claude Code specific tool names as intent, then use the equivalent Codex workflow available in the current session.
- When the source command references `AskUserQuestion`, ask the user directly only when the decision cannot be inferred safely.
- When the source command references Claude `Task` subagents, follow the current Codex delegation policy; if delegation is unavailable or not appropriate, do the work locally or report the limitation.
- Prefer existing scripts and structured parsers over ad hoc text manipulation.
- Keep changes additive unless the source command explicitly requires an edit and the user has requested that mode.
- Do not remove, rename, or weaken Claude Code files while adapting the workflow for Codex.

## Command-Specific Notes

- Auto-detect the project stack before running commands, and only run tools that exist for that repo.
- With `--fix`, keep fixes scoped to the detected project and report anything requiring manual review.

## Completion

End with a concise summary of actions taken, files changed, verification run, and any blocked items. If the source command is audit/report-only, produce the report and do not mutate the filesystem.
