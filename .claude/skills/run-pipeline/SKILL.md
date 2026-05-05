---
name: run-pipeline
description: Multi-project pipeline orchestrator — triage, execute, PR, review, deploy with safety gates
allowed-tools: Bash, Read, Write, Glob, Grep, Edit, AskUserQuestion
---

# Run Pipeline

Codex adapter for `/run-pipeline`.

**Arguments:** <company> <prd1> [prd2...] [--dry-run] [--resume <id>] [--status]

## Source Of Truth

Read `.claude/commands/run-pipeline.md` first. That slash command owns the workflow, flags, safety gates, file locations, and completion criteria. This skill exists so Codex can discover and execute the same HQ capability without duplicating the full command body.

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

- This command delegates execution to `scripts/run-pipeline.sh`. If that script is absent in a scaffold, report the missing backbone as a blocked runtime dependency instead of simulating the pipeline.
- Preserve dry-run, resume, and status modes before launching any long-running pipeline.

## Completion

End with a concise summary of actions taken, files changed, verification run, and any blocked items. If the source command is audit/report-only, produce the report and do not mutate the filesystem.
