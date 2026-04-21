---
description: Project or session retrospective — review what happened, surface patterns, feed learnings back to /learn
allowed-tools: Read, Write, Glob, Grep, Bash(git:*), Bash(qmd:*), AskUserQuestion
argument-hint: [company] [project-slug | --session]
visibility: public
pack: dev
---

# /retro - Retrospective

Generate a retrospective for a completed project or recent work session. Surfaces patterns, tracks what went well and what didn't, and feeds learnings back into HQ's policy system via `/learn`.

**Input:** $ARGUMENTS

**Pipeline:** `/run-project` completes → **`/retro`** → `/learn` (per pattern)

## Steps

1. Load the retro skill from `.claude/skills/retro/SKILL.md`
2. Determine mode: **PROJECT** (slug provided) or **SESSION** (`--session` flag, or no slug)
3. Resolve company context (manifest lookup, cwd inference)
4. Execute: data collection → analysis → pattern detection → learning extraction → write report
5. Output report to `workspace/reports/{slug}-retro.md`
6. Reindex: `qmd update 2>/dev/null || true`
