---
trigger: always_on
---

This is an HQ workspace. Follow the HQ charter in `.claude/CLAUDE.md` (the
same file Claude Code, Codex, Cursor, and Grok load). `AGENTS.md` at the
workspace root is a symlink to that charter, and Antigravity reads it
natively.

Antigravity does not expand the charter's `@file` import lines, so read these
files at the start of every task, in this order, and treat them as part of
the charter:

1. `.claude/personal-context.md` (always-loaded safety context)
2. `personal/CLAUDE.md` (the owner's personal overlay)

HQ skills are available as slash commands: Antigravity reads `.agents/skills`,
which is a symlink to `.claude/skills`.

HQ hook guards (policy reminders on each prompt, the scope and secret guards,
automatic Work Mesh presence) do not run in Antigravity yet. Until they do:

- Before company or repo work, resolve the company and read the policy files
  under `companies/<company>/policies/` and the repo's `.claude/policies/`
  yourself. Hard policies there are binding.
- Report Work Mesh state by hand with `hq mesh session task-status`,
  `hq mesh session blocked`, or `hq mesh session note`, each with `--enqueue`.
- Never read or print secrets. Use `hq secrets exec` or `hq run`.

This file is the Antigravity equivalent of `.cursor/rules/hq.mdc`. Files under
`.agents/rules/` need `trigger:` frontmatter or Antigravity skips them.
