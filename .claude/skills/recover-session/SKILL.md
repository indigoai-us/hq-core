---
name: recover-session
description: Recover dead sessions that hit context limits without running /handoff
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion
---

# Recover Session

Codex adapter for `/recover-session`.

**Arguments:** [--days N] [--session UUID] [--dry-run]

## Source Of Truth

Read `.claude/commands/recover-session.md` first. That slash command owns the workflow, flags, safety gates, file locations, and completion criteria. This skill exists so Codex can discover and execute the same HQ capability without duplicating the full command body.

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

- This command recovers Claude Code session JSONL data. In Codex, treat Codex transcript recovery as out of scope unless a matching source format is documented.
- Never read whole large JSONL files into context; stream or sample exactly as the command directs.

## Completion

End with a concise summary of actions taken, files changed, verification run, and any blocked items. If the source command is audit/report-only, produce the report and do not mutate the filesystem.
