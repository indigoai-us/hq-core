---
id: hq-core-vs-personal-skill-location-and-rename
title: Core skills live at .claude/skills/; personal skills are authored in personal/skills/ and bridged
when: skill
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-05-19
updated: 2026-05-19
source: session-learning
---

## Rule

ALWAYS: core (release-shippable, non-namespaced) HQ skills live directly at `.claude/skills/<name>/SKILL.md`; personal skills are authored at `personal/skills/<name>/` and bridged to `.claude/skills/personal:<name>/` by reindex. Renaming or moving a personal skill to core means: create the core dir at `.claude/skills/<name>/`, and delete BOTH `personal/skills/<old>` AND the bridged `.claude/skills/personal:<old>` symlink (otherwise the stale bridged symlink lingers).

## Rationale

reindex only adds/refreshes bridged symlinks for entries that still exist in `personal/skills/`; it does not garbage-collect the bridged `.claude/skills/personal:<old>` symlink after the source is removed or relocated. Deleting only the `personal/skills/<old>` source leaves a dangling `personal:<old>` slash command surfaced to Claude Code and Codex, causing confusing duplicate/stale invocations after a personal→core promotion.
