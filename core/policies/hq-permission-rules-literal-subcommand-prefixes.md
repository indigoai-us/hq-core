---
id: hq-permission-rules-literal-subcommand-prefixes
title: Claude Code permission rules are literal command-prefix matchers — list each subcommand explicitly
scope: global
trigger: When adding, auditing, or debugging `permissions.allow` / `permissions.ask` entries in `.claude/settings.json` or `.claude/settings.local.json`
when: settings.json || settings.local.json
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-20
updated: 2026-04-20
source: session-learning
---

## Rule

When pre-approving multi-subcommand CLIs (`git`, `gh`, `npm`, `pnpm`, `vercel`, `docker`, etc.) in the `permissions.allow` list, list each subcommand prefix individually. Do not assume a top-level wildcard like `Bash(git:*)` covers nested subcommands.

```jsonc
// GOOD — each subcommand listed individually
"Bash(git rev-parse:*)",
"Bash(git symbolic-ref:*)",
"Bash(git diff:*)",
"Bash(git log:*)",
"Bash(git status:*)",

// BAD — assumes top-level wildcard cascades
"Bash(git:*)"   // does NOT auto-approve `git rev-parse --show-toplevel`
```

Before shipping a new skill/command that invokes a CLI subcommand, grep `.claude/settings.json` + `.claude/settings.local.json` for that exact `Bash(<cli> <subcommand>:*)` shape. If missing, add it. Never paper over a prompt-interrupt by adding `Bash(<cli>:*)` as a catch-all.

## Rationale

Claude Code's permission engine treats the string inside `Bash(...)` as a literal prefix against the final command line. `Bash(git:*)` matches a command line that starts with `git ` (no subcommand) or `git:anything`, but `git rev-parse --show-toplevel` starts with `git rev-parse` — a distinct prefix that must be listed as its own rule.

This is why HQ's checked-in `.claude/settings.json` carries dozens of per-subcommand git entries (`git commit:*`, `git log:*`, `git rev-parse:*`, `git symbolic-ref:*`, `git worktree:*`, …) rather than a single `git:*`. Each entry corresponds to a specific command shape the orchestrator or a skill needs to run without interrupting for approval.

The dual cost of this literal-matching design is:
- Per-CLI entries grow linearly with subcommand surface area
- Broad wildcards feel safer than they are — `Bash(rm:*)` matches `rm -rf /` just as easily as `rm /tmp/foo` (see `hq-rm-permission-allow-scope-paths`)

The benefit is that the ask gate is explicit and auditable: every automated invocation has a matching rule, and every unlisted shape prompts for approval. Don't collapse specificity into convenience.

Composes with `hq-settings-local-for-personal-allows` (which file to edit), `hq-permissions-fan-out-edit-write-multiedit` (Edit/Write/MultiEdit must each be listed), and `hq-rm-permission-allow-scope-paths` (rm specifically must be path-scoped).
