---
name: handoff-and-archive
description: "Run /handoff, then archive this Claude Code desktop session. Shortcut for /handoff --archive. Triggers: \"handoff and archive\", \"wrap up and close this session\"."
allowed-tools: Skill, Read
argument-hint: "[handoff message]"
---

# /handoff-and-archive — handoff, then close this session

**Input:** $ARGUMENTS

This is a shortcut. It runs `/handoff` with `--archive` added, so the
session is archived after the handoff is saved and reported.

## Process

1. Invoke the `handoff` skill with the `Skill` tool. Pass `--archive`
   followed by the input above (if any) as its arguments. If the input
   already contains `--no-archive`, drop that flag. Running this command
   means the user wants the session archived.
2. Follow the handoff skill exactly, including its Step 7. Step 7 decides
   with `core/scripts/handoff-archive-decision.sh` and archives the session
   through `archive_session` only when that script prints `archive: yes`.
3. If the `Skill` tool is not available (for example in Codex), read
   `.claude/skills/handoff/SKILL.md` and follow it with `--archive` as the
   handoff arguments.

## Rules

- Never archive before the handoff has finished. The handoff skill's Step 7
  is the only place the session is archived.
- The handoff skill's refusals still apply: the session stays open when a
  follow-up recovery command is pending, when the handoff files are missing,
  when its worktree has uncommitted changes, when its branch has an open PR,
  when it has background work running, when it has an ask waiting on the
  owner, when one of those checks cannot run, or outside the desktop app. Say
  so in one plain sentence.
- Do not repeat the handoff report. The handoff skill writes it.
