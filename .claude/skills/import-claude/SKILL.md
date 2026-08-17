---
name: import-claude
description: "Deprecated alias for /import-context — bootstrap HQ from your prior AI footprint (Claude Code, Codex, Grok, claude.ai history plus on-disk artifacts)."
allowed-tools: Skill
---

# /import-claude — Deprecated Alias

This skill was renamed to `/import-context`: it now covers the full prior AI footprint (Claude Code, Codex, Grok, and claude.ai conversation history in addition to on-disk Claude artifacts), so the old name undersold it.

Print one line — `/import-claude is now /import-context — running it.` — then invoke the `import-context` skill with all of `$ARGUMENTS` passed through unchanged. Do not duplicate any import logic here.
