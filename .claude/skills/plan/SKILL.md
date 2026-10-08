---
name: plan
description: "Deprecated: forwards to /prd. Use /prd to create a PRD. This stub is removed in hq-core 16.0.0."
allowed-tools: Read, Skill
---

# Plan (deprecated)

`/plan` is deprecated. `/prd` is the command for creating a PRD.

1. Print one line: "/plan is deprecated; running /prd instead."
2. Invoke the `prd` skill with the same arguments this command received
   (`$ARGUMENTS`), unchanged. `/plan some idea` runs `/prd some idea`.
3. Do nothing else. The prd skill owns the interview and all output.

The prd skill ships only in the HQ checkout (`.claude/skills/prd/SKILL.md`), so
this stub is not packaged for standalone Codex or plugin installs.
