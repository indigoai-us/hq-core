---
name: newworker
description: Scaffold a new worker with skills, tools, and knowledge
allowed-tools: Read, Write, Edit, AskUserQuestion
---

# Newworker

Codex adapter for `/newworker`.

**Arguments:** Use the user's request as `$ARGUMENTS` for the source command.

## Source Of Truth

Read `.claude/commands/newworker.md` first. That slash command owns the workflow, flags, safety gates, file locations, and completion criteria. This skill exists so Codex can discover and execute the same HQ capability without duplicating the full command body.

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

- Follow the TypeScript/Node worker convention from the command; do not introduce Python worker scaffolds.
- If a PRD is needed first, tell the user and route through planning rather than inventing a worker spec.

## Completion

End with a concise summary of actions taken, files changed, verification run, and any blocked items. If the source command is audit/report-only, produce the report and do not mutate the filesystem.
