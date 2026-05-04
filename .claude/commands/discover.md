---
description: Pull a repo into HQ at latest main, explore it in parallel, and synthesize knowledge + (gated) policies
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Agent
argument-hint: "<repo-url|org/name|path> [--company <slug>] [--private] [--no-policies]"
visibility: public
public: true
---

# /discover

<!-- hq-core: public -->

Read `.claude/skills/discover/SKILL.md` and execute that workflow.

Use `$ARGUMENTS` as the repo identifier (URL, `<org>/<name>`, or local path) plus optional `--company`, `--private`, `--no-policies` flags.
